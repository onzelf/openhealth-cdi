#!/usr/bin/env python3
"""OpenHealth hub with FLICS envelope-driven coordination.

OpenHealth remains authoritative for experiment lifecycle, evidence artefacts,
client registration, and the React/Vite API contract.

FLICS remains authoritative for Redis envelope events and backend binding.
There is no pass-through governance mode and no fallback ALLOW path.
"""

from __future__ import annotations

import asyncio
import base64
import csv
import json
import os
import secrets
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import redis.asyncio as redis
import requests
import uvicorn
from fastapi import FastAPI, Header, HTTPException, Request
from pydantic import BaseModel, Field

# ---------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------

RUN_ID = os.getenv("RUN_ID", "local-pathmnist-ab-001")
RUNS_DIR = Path(os.getenv("RUNS_DIR", "/vault/runs"))
VAULT_ROOT = Path(os.getenv("VAULT_ROOT", "/vault"))

DATASET = os.getenv("DATASET", "medmnist")
DATASET_SUBSET = os.getenv("DATASET_SUBSET", "pathmnist")
FLOWER_ROUNDS = int(os.getenv("FLOWER_ROUNDS", "10"))
MIN_CLIENTS = int(os.getenv("MIN_CLIENTS", "2"))
LOCAL_EPOCHS = int(os.getenv("LOCAL_EPOCHS", "1"))
BATCH_SIZE = int(os.getenv("BATCH_SIZE", "32"))
LEARNING_RATE = float(os.getenv("LEARNING_RATE", "0.001"))

# HTTP control endpoint expected after the Flower server is ported with the
# FLICS /bind_envelope contract. This is not the Flower gRPC address.
FLOWER_BACKEND_URL = os.getenv(
    "FLOWER_BACKEND_URL",
    "http://vfp-core-flower-server:8081",
).rstrip("/")

REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379/0")
FCAC_ENVELOPE_CHANNEL = os.getenv(
    "FCAC_ENVELOPE_CHANNEL",
    "fcac:envelopes:created",
)
BIND_RETRY_SECONDS = float(os.getenv("BIND_RETRY_SECONDS", "2"))

ORGS_JSON = os.getenv("ORGS_JSON", "{}")

ISSUER_A_URL = os.getenv(
    "ISSUER_A_URL",
    "http://issuer-hospitala:8080",
).rstrip("/")
ISSUER_B_URL = os.getenv(
    "ISSUER_B_URL",
    "http://issuer-hospitalb:8080",
).rstrip("/")
SIGNER_URL = os.getenv(
    "SIGNER_URL",
    "http://holder-signer:8090",
).rstrip("/")
DPOP_HTU = os.getenv(
    "DPOP_HTU",
    "https://verifier.local/admission/check",
)

VERIFIER_URL = os.getenv(
    "VERIFIER_URL",
    "https://verifier.local:8443",
).rstrip("/")
CA_CRT = os.getenv("CA_CRT", "/run/certs/ca.crt")
HUB_CERT_CRT = os.getenv("HUB_CERT_CRT", "/run/certs/hub.crt")
HUB_CERT_KEY = os.getenv("HUB_CERT_KEY", "/run/certs/hub.key")

KYO_ORGANISATIONS = {
    "hospital-a": "org://HospitalA",
    "hospital-b": "org://HospitalB",
}
KYO_BIND_PAYLOAD = {
    "participants": [
        {
            "org": "org://HospitalA",
            "sigma_part": {
                "jurisdiction": "EU",
                "sensitivity": "CLINICAL",
            },
        },
        {
            "org": "org://HospitalB",
            "sigma_part": {
                "jurisdiction": "US",
                "sensitivity": "PHI",
            },
        },
    ],
    "quorum": {"k": 2, "n": 2},
    "scope": {"model": "FedMNIST-v1", "backend": "flower_server"},
    "allowed_ops": ["start", "train", "predict"],
}

PATHMNIST_QUERY_TISSUES = [
    "adipose",
    "background",
    "lymphocytes",
    "mucus",
    "smooth_muscle",
    "normal_colon_mucosa",
    "cancer_associated_stroma",
    "colorectal_adenocarcinoma_epithelium",
]

AB_PRINCIPALS: Dict[str, Dict[str, Any]] = {
    "Audrey": {
        "organisation": "Hospital A",
        "issuer_url": ISSUER_A_URL,
        "profile": "PATHMNIST_OTHER_TISSUE_READER",
        "allowed_tissues": ["background", "lymphocytes"],
    },
    "Bob": {
        "organisation": "Hospital B",
        "issuer_url": ISSUER_B_URL,
        "profile": "PATHMNIST_CANCER_ASSOCIATED_READER",
        "allowed_tissues": [
            "cancer_associated_stroma",
            "colorectal_adenocarcinoma_epithelium",
        ],
    },
}

# ---------------------------------------------------------------------
# App and models
# ---------------------------------------------------------------------

app = FastAPI(
    title="OpenHealth VFP Hub",
    description=(
        "OpenHealth experiment orchestration with FLICS envelope-driven "
        "admission governance."
    ),
    version="0.4.0",
)


class BackendRegistration(BaseModel):
    backend_id: str = Field(..., examples=["flower-local"])
    backend_type: str = Field(..., examples=["flower_server"])
    url: str = Field(..., examples=["http://vfp-core-flower-server:8081"])
    metadata: Dict[str, Any] = Field(default_factory=dict)


class ExperimentInitialiseRequest(BaseModel):
    run_id: str = RUN_ID
    dataset: str = DATASET
    dataset_subset: str = DATASET_SUBSET
    rounds: int = FLOWER_ROUNDS
    min_clients: int = MIN_CLIENTS
    local_epochs: int = LOCAL_EPOCHS


class ClientRegistration(BaseModel):
    run_id: str = RUN_ID
    org_id: str
    org_label: Optional[str] = None
    data_partition: Optional[int] = None
    metadata: Dict[str, Any] = Field(default_factory=dict)


class PredictionRequest(BaseModel):
    envelope_id: str
    run_id: str = RUN_ID
    requested_tissues: List[str]
    jti: str
    topk: int = Field(default=3, ge=1, le=9)


class ABPredictionRequest(BaseModel):
    envelope_id: str
    run_id: str = RUN_ID
    principal: str
    requested_tissue: str
    topk: int = Field(default=3, ge=1, le=9)


class KyoApprovalRequest(BaseModel):
    bind_id: str
    code: str


class HolderEctMintRequest(BaseModel):
    envelope_id: str


class UserInferenceRequest(BaseModel):
    principal: str
    envelope_id: str
    run_id: str = RUN_ID
    requested_tissue: str
    topk: int = Field(default=3, ge=1, le=9)


# ---------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------

backend_registry: Dict[str, Dict[str, Any]] = {}
active_envelopes: Dict[str, Dict[str, Any]] = {}
pending_envelopes: Dict[str, Dict[str, Any]] = {}

experiment_state: Dict[str, Any] = {
    "run_id": RUN_ID,
    "status": "waiting",
    "registered_clients": {},
    "min_clients": MIN_CLIENTS,
    "flower_server_ready": False,
    "active_envelope_id": None,
    "backend_bound": False,
}

redis_client: Optional[redis.Redis] = None
envelope_listener_task: Optional[asyncio.Task[Any]] = None
pending_binding_task: Optional[asyncio.Task[Any]] = None
envelope_binding_lock = asyncio.Lock()
holder_runtime_credentials: Dict[Tuple[str, str], Dict[str, Any]] = {}


# ---------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------

def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def model_dict(model: BaseModel) -> Dict[str, Any]:
    if hasattr(model, "model_dump"):
        return model.model_dump()  # type: ignore[attr-defined]
    return model.dict()


def run_dir(run_id: str = RUN_ID) -> Path:
    path = RUNS_DIR / run_id
    path.mkdir(parents=True, exist_ok=True)
    return path


def write_json(path: Path, payload: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def append_event(
    event_type: str,
    run_id: str = RUN_ID,
    **kwargs: Any,
) -> None:
    event = {
        "timestamp": utc_now(),
        "run_id": run_id,
        "component": "vfp-core/hub",
        "event_type": event_type,
        **kwargs,
    }
    with (run_dir(run_id) / "events.jsonl").open("a", encoding="utf-8") as f:
        f.write(json.dumps(event) + "\n")


def verifier_request(
    method: str,
    path: str,
    **kwargs: Any,
) -> Dict[str, Any]:
    """Call the verifier through the Hub's existing mTLS identity."""
    try:
        response = requests.request(
            method,
            VERIFIER_URL + path,
            timeout=15,
            verify=CA_CRT,
            cert=(HUB_CERT_CRT, HUB_CERT_KEY),
            **kwargs,
        )
    except Exception as exc:
        raise HTTPException(502, f"verifier_unavailable:{exc}") from exc

    if not response.ok:
        try:
            detail = response.json().get("detail", response.text)
        except ValueError:
            detail = response.text
        raise HTTPException(response.status_code, str(detail))

    try:
        return response.json()
    except ValueError as exc:
        raise HTTPException(502, "verifier_returned_non_json") from exc


def request_prediction_admission(
    *,
    envelope_id: str,
    run_id: str,
    requested_tissues: List[str],
    jti: str,
    authorization: str,
    dpop: str,
    dpop_nonce: str,
) -> Dict[str, Any]:
    admission_request = {
        "envelope_id": envelope_id,
        "run_id": run_id,
        "resource": "pathmnist-colon-pathology",
        "action": "query_model",
        "purpose": "approved_model_query",
        "requested_tissues": requested_tissues,
        "jti": jti,
    }

    try:
        verifier = requests.post(
            os.getenv(
                "VERIFIER_URL",
                "https://verifier.local:8443",
            ).rstrip("/") + "/admission/check",
            headers={
                "Authorization": authorization,
                "DPoP": dpop,
                "X-DPoP-Nonce": dpop_nonce,
            },
            json=admission_request,
            timeout=15,
            verify=os.getenv("CA_CRT", "/run/certs/ca.crt"),
            cert=(
                os.getenv("HUB_CERT_CRT", "/run/certs/hub.crt"),
                os.getenv("HUB_CERT_KEY", "/run/certs/hub.key"),
            ),
        )
        verifier.raise_for_status()
        admission = verifier.json()
    except Exception as exc:
        raise HTTPException(502, f"verifier_error:{exc}") from exc

    append_event(
        "prediction_admission",
        run_id=run_id,
        envelope_id=envelope_id,
        requested_tissues=requested_tissues,
        jti=jti,
        **admission,
    )
    return admission


def principal_runtime_key(
    envelope_id: str,
    principal: str,
) -> Tuple[str, str]:
    return envelope_id, principal


def compact_ect_preview(token: str) -> str:
    if not token:
        return ""
    token = str(token)
    if len(token) <= 24:
        return f"ECT={token}"
    return f"ECT={token[:16]}…{token[-8:]}"


def decode_ect_claims(token: str) -> Dict[str, Any]:
    try:
        parts = token.split(".")
        if len(parts) != 3:
            raise ValueError("not_compact_jws")
        payload = parts[1]
        payload += "=" * ((4 - len(payload) % 4) % 4)
        claims = json.loads(
            base64.urlsafe_b64decode(payload).decode("utf-8")
        )
        if not isinstance(claims, dict):
            raise ValueError("payload_not_object")
        return claims
    except Exception as exc:
        raise HTTPException(502, f"ect_decode_failed:{exc}") from exc


def selected_envelope_binding_state(
    backend_state: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    backend_state = backend_state or backend_reported_state()
    bound_envelope_payload = backend_state.get("bound_envelope") or {}
    selected_id = bound_envelope_payload.get("envelope_id")
    if not selected_id:
        return {
            "selected_envelope_id": None,
            "bound": False,
            "backend_state": backend_state,
        }
    return {
        "selected_envelope_id": selected_id,
        "bound": bool(backend_state.get("available", False) and selected_id),
        "backend_state": backend_state,
    }


def issuer_member_lookup(
    issuer_url: str,
    principal: str,
) -> Optional[bool]:
    try:
        response = requests.get(
            issuer_url.rstrip("/") + "/members",
            timeout=10,
        )
        response.raise_for_status()
        payload = response.json()
    except Exception:
        return None

    members = payload.get("members") or []
    return any(str(member.get("sub", "")) == principal for member in members)


def mint_principal_ect(
    principal: str,
    principal_context: Dict[str, Any],
    envelope_id: str,
) -> str:
    try:
        response = requests.post(
            principal_context["issuer_url"] + "/mint",
            json={
                "sub": principal,
                "profile": principal_context["profile"],
                "envelope_id": envelope_id,
            },
            timeout=15,
        )
    except Exception as exc:
        raise HTTPException(502, f"issuer_error:{exc}") from exc

    if not response.ok:
        raise HTTPException(
            response.status_code,
            f"issuer_mint_failed:{response.text}",
        )
    ect = response.json().get("ect")
    if not ect:
        raise HTTPException(502, "issuer_mint_failed:missing_ect")
    return str(ect)


def sign_principal_dpop(
    principal: str,
    envelope_id: str,
    nonce: str,
    jti: str,
) -> str:
    try:
        response = requests.post(
            SIGNER_URL + "/dpop/sign",
            json={
                "sub": principal,
                "htu": DPOP_HTU,
                "htm": "POST",
                "jti": jti,
                "nonce": nonce,
                "envelope_id": envelope_id,
            },
            timeout=15,
        )
    except Exception as exc:
        raise HTTPException(502, f"signer_error:{exc}") from exc

    if not response.ok:
        raise HTTPException(
            response.status_code,
            f"dpop_sign_failed:{response.text}",
        )
    dpop = response.json().get("dpop")
    if not dpop:
        raise HTTPException(502, "dpop_sign_failed:missing_dpop")
    return str(dpop)


def parse_orgs() -> Dict[str, Dict[str, Any]]:
    try:
        payload = json.loads(ORGS_JSON)
        return payload if isinstance(payload, dict) else {}
    except json.JSONDecodeError:
        return {}


def write_participants(run_id: str = RUN_ID) -> None:
    orgs = parse_orgs()
    payload = {
        "run_id": run_id,
        "participants": [
            {
                "org_id": org_id,
                "label": org.get("label"),
                "partition": org.get("partition"),
                "enabled": org.get("enabled", True),
            }
            for org_id, org in orgs.items()
        ],
    }
    write_json(run_dir(run_id) / "participants.json", payload)


def ensure_metrics_file(run_id: str = RUN_ID) -> None:
    path = run_dir(run_id) / "metrics.csv"
    if not path.exists():
        write_metrics_header(run_id)


def write_metrics_header(run_id: str = RUN_ID) -> None:
    path = run_dir(run_id) / "metrics.csv"
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(
            [
                "run_id",
                "round",
                "phase",
                "client_count",
                "failure_count",
                "loss",
                "accuracy",
                "train_loss",
                "train_accuracy",
            ]
        )


def write_experiment_config(req: ExperimentInitialiseRequest) -> None:
    config = {
        "run_id": req.run_id,
        "dataset": req.dataset,
        "dataset_subset": req.dataset_subset,
        "aggregation_strategy": "FedAvg",
        "rounds": req.rounds,
        "min_clients": req.min_clients,
        "local_epochs": req.local_epochs,
        "batch_size": BATCH_SIZE,
        "learning_rate": LEARNING_RATE,
        "flower_backend_url": FLOWER_BACKEND_URL,
        "governance": {
            "model": "FCaC",
            "envelope_channel": FCAC_ENVELOPE_CHANNEL,
            "admission": "envelope-driven",
            "pass_through": False,
        },
        "organisations": parse_orgs(),
    }
    write_json(run_dir(req.run_id) / "experiment_config.json", config)


def write_reproduce_readme(req: ExperimentInitialiseRequest) -> None:
    content = f"""# Reproduce run `{req.run_id}`

## Experiment

- Dataset: `{req.dataset}`
- Dataset subset: `{req.dataset_subset}`
- Aggregation strategy: `FedAvg`
- Rounds: `{req.rounds}`
- Local epochs: `{req.local_epochs}`
- Minimum clients: `{req.min_clients}`

## Governance

- Model: FCaC
- Admission: envelope-driven
- Redis channel: `{FCAC_ENVELOPE_CHANNEL}`
- Pass-through fallback: disabled

The experiment can start only after a FLICS envelope has been created and
successfully bound to the selected backend.
"""
    (run_dir(req.run_id) / "README_reproduce_this_run.md").write_text(
        content,
        encoding="utf-8",
    )


def initialise_default_run() -> None:
    req = ExperimentInitialiseRequest()
    write_experiment_config(req)
    write_participants(req.run_id)
    ensure_metrics_file(req.run_id)
    write_reproduce_readme(req)
    append_event(
        "experiment_initialised",
        run_id=req.run_id,
        dataset=req.dataset,
        dataset_subset=req.dataset_subset,
        rounds=req.rounds,
        min_clients=req.min_clients,
        local_epochs=req.local_epochs,
    )


def backend_for_type(backend_type: str) -> Optional[Dict[str, Any]]:
    direct = backend_registry.get(backend_type)
    if direct is not None:
        return direct

    for backend in backend_registry.values():
        if backend.get("backend_type") == backend_type:
            return backend

    return None


def current_experiment_status(run_id: str = RUN_ID) -> Dict[str, Any]:
    registered_clients = experiment_state.get("registered_clients", {})
    registered_client_ids = sorted(registered_clients.keys())
    registered_client_count = len(registered_client_ids)
    min_clients = int(experiment_state.get("min_clients", MIN_CLIENTS))

    active_envelope_id = experiment_state.get("active_envelope_id")
    backend_registered = bool(backend_registry)
    backend_bound = bool(experiment_state.get("backend_bound", False))
    selected_summary = selected_run_summary() if active_envelope_id else None
    execution_status = experiment_state.get("status", "waiting")
    backend_state = (
        backend_reported_state()
        if execution_status == "running"
        else {}
    )
    training = backend_state.get("training") or {}
    model_run_id = (
        active_training_run_id(backend_state)
        if execution_status == "running"
        else (selected_summary or {}).get("run_id")
    )

    can_start = (
        experiment_state.get("status") == "waiting"
        and experiment_state.get("flower_server_ready", False)
        and active_envelope_id is not None
        and backend_registered
        and backend_bound
        and registered_client_count >= min_clients
    )

    return {
        "run_id": run_id,
        "model_run_id": model_run_id,
        "status": execution_status,
        "training": training,
        "flower_server_ready": experiment_state.get(
            "flower_server_ready",
            False,
        ),
        "registered_clients": registered_client_ids,
        "registered_client_count": registered_client_count,
        "min_clients": min_clients,
        "active_envelope_id": active_envelope_id,
        "backend_registered": backend_registered,
        "backend_bound": backend_bound,
        "can_start": can_start,
        "governance": {
            "model": "FCaC",
            "pass_through": False,
        },
    }

# ---------------------------------------------------------------------
# Redis and envelope handling
# ---------------------------------------------------------------------

async def get_redis() -> redis.Redis:
    global redis_client

    if redis_client is None:
        redis_client = redis.from_url(REDIS_URL, decode_responses=True)

    await redis_client.ping()
    return redis_client


async def subscribe_to_envelope_events() -> None:
    """Listen continuously for FLICS envelope creation events."""
    while True:
        pubsub = None
        try:
            client = await get_redis()
            pubsub = client.pubsub()
            await pubsub.subscribe(FCAC_ENVELOPE_CHANNEL)
            print(
                f"[hub] subscribed to {FCAC_ENVELOPE_CHANNEL}",
                flush=True,
            )

            while True:
                message = await pubsub.get_message(
                    ignore_subscribe_messages=True,
                    timeout=1.0,
                )
                if message is None:
                    await asyncio.sleep(0.05)
                    continue

                envelope = json.loads(message["data"])
                await handle_envelope_created(envelope)

        except asyncio.CancelledError:
            raise
        except Exception as exc:
            append_event(
                "envelope_subscription_error",
                error=str(exc),
                retry_seconds=2,
            )
            await asyncio.sleep(2)
        finally:
            if pubsub is not None:
                try:
                    await pubsub.unsubscribe(FCAC_ENVELOPE_CHANNEL)
                    await pubsub.aclose()
                except Exception:
                    pass


async def bind_envelope_to_backend(
    envelope: Dict[str, Any],
    backend: Dict[str, Any],
) -> bool:
    """Record an envelope binding without changing experiment status."""
    envelope_id = envelope.get("envelope_id")
    scope = envelope.get("scope") or {}
    envelope_key = str(envelope_id)

    async with envelope_binding_lock:
        if envelope_key not in pending_envelopes:
            return experiment_state.get("active_envelope_id") == envelope_id

        bind_payload = {
            "envelope_id": envelope_id,
            "allowed_ops": envelope.get("allowed_ops", []),
            "policy_hash": envelope.get("policy_hash"),
            "valid_until": envelope.get("valid_until"),
            "participants": envelope.get("participants", []),
            "scope": scope,
        }

        try:
            response = await asyncio.to_thread(
                requests.post,
                f"{backend['url'].rstrip('/')}/bind_envelope",
                json=bind_payload,
                timeout=10,
            )
            response.raise_for_status()
        except Exception as exc:
            experiment_state["backend_bound"] = False
            append_event(
                "envelope_bind_failed",
                envelope_id=envelope_id,
                backend_id=backend.get("backend_id"),
                backend_url=backend.get("url"),
                error=str(exc),
            )
            return False

        active_envelopes[envelope_id] = {
            **envelope,
            "backend_id": backend.get("backend_id"),
            "bound_at": utc_now(),
        }
        experiment_state["active_envelope_id"] = envelope_id
        experiment_state["backend_bound"] = True
        pending_envelopes.pop(envelope_key, None)

        append_event(
            "envelope_bound",
            envelope_id=envelope_id,
            backend_id=backend.get("backend_id"),
            backend_url=backend.get("url"),
        )
        return True


async def retry_pending_envelope_bindings() -> None:
    while True:
        await asyncio.sleep(BIND_RETRY_SECONDS)

        for envelope in list(pending_envelopes.values()):
            scope = envelope.get("scope") or {}
            backend_type = scope.get("backend", "flower_server")
            backend = backend_for_type(backend_type)
            if backend is not None:
                await bind_envelope_to_backend(envelope, backend)


async def handle_envelope_created(envelope: Dict[str, Any]) -> None:
    """Queue a FLICS envelope and bind it once its backend is registered."""
    envelope_id = envelope.get("envelope_id")
    if not envelope_id:
        append_event(
            "envelope_rejected",
            reason="missing_envelope_id",
            envelope=envelope,
        )
        return

    scope = envelope.get("scope") or {}
    backend_type = scope.get("backend", "flower_server")
    pending_envelopes[str(envelope_id)] = envelope

    append_event(
        "envelope_received",
        envelope_id=envelope_id,
        backend_type=backend_type,
        policy_hash=envelope.get("policy_hash"),
        scope=scope,
    )

    backend = backend_for_type(backend_type)
    if backend is None:
        append_event(
            "envelope_queued",
            envelope_id=envelope_id,
            backend_type=backend_type,
            reason="backend_not_registered",
        )
        return

    await bind_envelope_to_backend(envelope, backend)


# ---------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------

@app.on_event("startup")
async def on_startup() -> None:
    global envelope_listener_task, pending_binding_task

    run_dir(RUN_ID)
    initialise_default_run()

    # Surface Redis configuration errors during startup.
    await get_redis()

    envelope_listener_task = asyncio.create_task(
        subscribe_to_envelope_events()
    )
    pending_binding_task = asyncio.create_task(
        retry_pending_envelope_bindings()
    )
    append_event(
        "hub_ready",
        redis_url=REDIS_URL,
        envelope_channel=FCAC_ENVELOPE_CHANNEL,
    )


@app.on_event("shutdown")
async def on_shutdown() -> None:
    global redis_client, envelope_listener_task, pending_binding_task

    tasks = [envelope_listener_task, pending_binding_task]
    for task in tasks:
        if task is not None:
            task.cancel()

    for task in tasks:
        if task is None:
            continue
        try:
            await task
        except asyncio.CancelledError:
            pass

    if redis_client is not None:
        await redis_client.aclose()
        redis_client = None


# ---------------------------------------------------------------------
# Health and backend registry
# ---------------------------------------------------------------------

@app.get("/health")
async def health() -> Dict[str, Any]:
    client = await get_redis()
    redis_ok = bool(await client.ping())
    return {
        "status": "ok",
        "component": "vfp-core/hub",
        "run_id": RUN_ID,
        "redis": redis_ok,
        "governance": "FCaC",
    }


@app.get("/status")
async def status() -> Dict[str, Any]:
    client = await get_redis()
    redis_ok = bool(await client.ping())
    return {
        "run_id": RUN_ID,
        "dataset": DATASET,
        "dataset_subset": DATASET_SUBSET,
        "flower_rounds": FLOWER_ROUNDS,
        "min_clients": MIN_CLIENTS,
        "redis": redis_ok,
        "registered_backends": list(backend_registry.values()),
        "active_envelopes": sorted(active_envelopes.keys()),
        "experiment": current_experiment_status(RUN_ID),
    }


@app.post("/backend/register")
async def backend_register(req: Request) -> Dict[str, Any]:
    """Accept both the FLICS and OpenHealth registration payloads."""
    payload = await req.json()

    backend_type = payload.get("backend_type") or payload.get("type")
    backend_url = payload.get("url")
    backend_id = payload.get("backend_id") or backend_type

    if not backend_id or not backend_type or not backend_url:
        raise HTTPException(
            status_code=400,
            detail="missing backend_id/backend_type/url",
        )

    backend = {
        "backend_id": str(backend_id),
        "backend_type": str(backend_type),
        "url": str(backend_url).rstrip("/"),
        "metadata": payload.get("metadata") or {},
        "registered_at": utc_now(),
    }
    backend_registry[backend["backend_id"]] = backend
    if backend["backend_type"] == "flower_server":
        experiment_state["flower_server_ready"] = True
    append_event("backend_registered", **backend)

    active_envelope_id = experiment_state.get("active_envelope_id")
    if active_envelope_id in active_envelopes:
        pending_envelopes[str(active_envelope_id)] = active_envelopes[
            active_envelope_id
        ]

    matching_envelopes = [
        envelope
        for envelope in list(pending_envelopes.values())
        if (envelope.get("scope") or {}).get(
            "backend",
            "flower_server",
        ) == backend["backend_type"]
    ]
    for envelope in matching_envelopes:
        await bind_envelope_to_backend(envelope, backend)

    return {
        "status": "registered",
        "backend": backend,
    }


@app.get("/backend/list")
def backend_list() -> Dict[str, Any]:
    return {
        "backends": list(backend_registry.values()),
    }


# ---------------------------------------------------------------------
# Administration: present verifier, backend, and vault state
# ---------------------------------------------------------------------

def backend_reported_state() -> Dict[str, Any]:
    backend = backend_for_type("flower_server")
    if backend is None:
        return {
            "available": False,
            "bound_envelope": None,
            "model_run_id": None,
            "training": None,
        }
    try:
        response = requests.get(
            f"{backend['url'].rstrip('/')}/status",
            timeout=5,
        )
        response.raise_for_status()
        payload = response.json()
        return {
            "available": True,
            "bound_envelope": payload.get("bound_envelope"),
            "model_run_id": payload.get("model_run_id"),
            "training": payload.get("training"),
        }
    except Exception as exc:
        return {
            "available": False,
            "bound_envelope": None,
            "model_run_id": None,
            "training": None,
            "error": str(exc),
        }


def envelope_model_evidence(envelope_id: str) -> Dict[str, Any]:
    evidence_path = VAULT_ROOT / envelope_id / "run.json"
    if not evidence_path.is_file():
        return {"available": False, "evidence": None}
    try:
        evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"available": False, "evidence": str(evidence_path)}

    model_path = (evidence.get("artifacts") or {}).get("model")
    model_available = bool(model_path and Path(model_path).is_file())
    return {
        "available": model_available,
        "evidence": str(evidence_path),
        "run_id": evidence.get("run_id"),
        "status": evidence.get("status"),
        "rounds_completed": evidence.get("rounds_completed"),
        "model": model_path,
    }


def selected_run_summary() -> Optional[Dict[str, Any]]:
    envelope_id = experiment_state.get("active_envelope_id")
    if not envelope_id:
        return None
    path = VAULT_ROOT / str(envelope_id) / "run.json"
    if not path.is_file():
        return None
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
        return payload if isinstance(payload, dict) else None
    except (OSError, ValueError):
        return None


def selected_artifact_path(name: str) -> Optional[Path]:
    summary = selected_run_summary()
    if summary is None:
        return None
    value = (summary.get("artifacts") or {}).get(name)
    return Path(value) if value else None


def active_training_run_id(
    backend_state: Optional[Dict[str, Any]] = None,
) -> Optional[str]:
    backend_state = backend_state or backend_reported_state()
    training = backend_state.get("training") or {}
    model_run_id = backend_state.get("model_run_id")
    if training.get("status") != "running" or not model_run_id:
        return None
    return str(model_run_id)


def active_envelope_registry() -> List[Dict[str, Any]]:
    verifier_status = verifier_request(
        "GET",
        "/status",
        params={"state": "ACTIVE"},
    )
    now = time.time()
    return [
        {
            **envelope,
            "model": envelope_model_evidence(str(envelope["envelope_id"])),
        }
        for envelope in verifier_status.get("envelopes", [])
        if not envelope.get("exp") or float(envelope["exp"]) > now
    ]


@app.get("/administration/boundary")
def administration_boundary() -> Dict[str, Any]:
    """Return the compact administration state the React boundary controls need."""
    active_registry = active_envelope_registry()
    backend_state = backend_reported_state()
    binding_state = selected_envelope_binding_state(backend_state)
    selected_id = binding_state.get("selected_envelope_id")
    selected_envelope = next(
        (
            envelope
            for envelope in active_registry
            if envelope.get("envelope_id") == selected_id
        ),
        None,
    )
    selected_model_run_id = None
    if selected_envelope is not None:
        selected_model_run_id = selected_envelope.get("model", {}).get(
            "run_id"
        )
    envelopes_payload = []
    for envelope in active_registry:
        envelope_id = str(envelope.get("envelope_id", ""))
        model = envelope.get("model") or {}
        envelopes_payload.append(
            {
                "envelope_id": envelope_id,
                "participants": envelope.get("participants") or [],
                "bound": bool(
                    envelope_id == selected_id
                    and binding_state.get("bound", False)
                ),
                "expiry": envelope.get("exp"),
                "model_available": bool(model.get("available", False)),
                "model_run_id": model.get("run_id"),
            }
        )

    holders_payload = []
    now = int(time.time())
    for principal, context in AB_PRINCIPALS.items():
        credential_key = principal_runtime_key(str(selected_id or ""), principal)
        credential = holder_runtime_credentials.get(credential_key)
        expires_at = credential.get("expires_at") if credential else None
        ect_status = "missing"
        ect_preview = ""
        if credential:
            expired = bool(expires_at and int(expires_at) <= now)
            credential["expired"] = expired
            if expired:
                ect_status = "expired"
            else:
                ect_status = "ready"
                ect_preview = compact_ect_preview(credential.get("ect", ""))
        enrollment = issuer_member_lookup(context["issuer_url"], principal)
        holders_payload.append(
            {
                "principal": principal,
                "organization": context["organisation"],
                "profile": context["profile"],
                "enrolled": enrollment,
                "enrollment_status": (
                    "enrolled"
                    if enrollment is True
                    else "not_enrolled"
                    if enrollment is False
                    else "unavailable"
                ),
                "ect_status": ect_status,
                "ect_preview": ect_preview,
                "envelope_id": selected_id,
                "expires_at": expires_at,
                "model_run_id": selected_model_run_id,
            }
        )

    return {
        "selected_envelope_id": selected_id,
        "envelopes": envelopes_payload,
        "holders": holders_payload,
        "can_train": current_experiment_status(RUN_ID).get("can_start", False),
    }


@app.get("/administration/envelopes")
def administration_envelopes() -> Dict[str, Any]:
    """Present authoritative envelope, backend, and model evidence."""
    active_registry = active_envelope_registry()
    backend_state = backend_reported_state()
    bound_envelope = backend_state.get("bound_envelope") or {}
    selected_id = bound_envelope.get("envelope_id")

    return {
        "active_envelopes": active_registry,
        "selected_envelope_id": selected_id,
        "selected_envelope": next(
            (
                envelope
                for envelope in active_registry
                if envelope.get("envelope_id") == selected_id
            ),
            None,
        ),
        "run_id": experiment_state.get("run_id", RUN_ID),
        "backend": backend_state,
    }


@app.post("/administration/holders/{principal}/mint-ect")
def administration_mint_holder_ect(
    principal: str,
    req: HolderEctMintRequest,
) -> Dict[str, Any]:
    """Mint and store a short-lived ECT for a holder for the selected envelope."""
    principal_context = AB_PRINCIPALS.get(principal)
    if principal_context is None:
        raise HTTPException(400, f"unknown_principal:{principal}")

    binding_state = selected_envelope_binding_state()
    selected_id = binding_state.get("selected_envelope_id")
    if not selected_id:
        raise HTTPException(409, "no_envelope_selected")
    if req.envelope_id != selected_id:
        raise HTTPException(409, "envelope_mismatch")
    if not binding_state.get("bound", False):
        raise HTTPException(409, "envelope_not_bound")

    enrollment = issuer_member_lookup(
        principal_context["issuer_url"],
        principal,
    )
    if enrollment is None:
        raise HTTPException(502, "issuer_members_unavailable")
    if enrollment is False:
        raise HTTPException(409, f"holder_not_enrolled:{principal}")

    active_envelope = next(
        (
            item
            for item in active_envelope_registry()
            if str(item.get("envelope_id")) == str(selected_id)
        ),
        None,
    )
    if active_envelope is None:
        raise HTTPException(404, "active_envelope_not_found")
    if active_envelope.get("exp") and float(active_envelope["exp"]) <= time.time():
        raise HTTPException(409, "selected_envelope_expired")

    ect = mint_principal_ect(principal, principal_context, selected_id)
    claims = decode_ect_claims(ect)
    if claims.get("envelope_id") != selected_id:
        raise HTTPException(502, "minted_ect_envelope_mismatch")
    try:
        expires_at = int(claims["exp"])
    except (KeyError, TypeError, ValueError) as exc:
        raise HTTPException(502, "minted_ect_missing_expiry") from exc
    if expires_at <= int(time.time()):
        raise HTTPException(502, "minted_ect_already_expired")

    credential_key = principal_runtime_key(selected_id, principal)
    holder_runtime_credentials[credential_key] = {
        "principal": principal,
        "envelope_id": selected_id,
        "ect": ect,
        "expires_at": expires_at,
        "expired": False,
    }

    return {
        "principal": principal,
        "envelope_id": selected_id,
        "ect_preview": compact_ect_preview(ect),
        "expires_at": expires_at,
        "ready": True,
    }


@app.post("/administration/envelopes/{envelope_id}/select")
async def administration_envelope_select(envelope_id: str) -> Dict[str, Any]:
    """Bind the exact active envelope selected by the administrator."""
    verifier_status = verifier_request("GET", "/status", params={"state": "ACTIVE"})
    envelope = next(
        (
            item
            for item in verifier_status.get("envelopes", [])
            if item.get("envelope_id") == envelope_id
        ),
        None,
    )
    if envelope is None:
        raise HTTPException(404, "active_envelope_not_found")
    if envelope.get("exp") and float(envelope["exp"]) <= time.time():
        raise HTTPException(409, "selected_envelope_expired")

    backend = backend_for_type((envelope.get("scope") or {}).get("backend", "flower_server"))
    if backend is None:
        raise HTTPException(409, "flower_backend_not_registered")

    binding = {
        "envelope_id": envelope_id,
        "allowed_ops": envelope.get("allowed_ops", []),
        "policy_hash": envelope.get("policy_hash"),
        "valid_until": envelope.get("exp"),
        "participants": envelope.get("participants", []),
        "scope": envelope.get("scope", {}),
    }
    pending_envelopes[envelope_id] = binding
    if not await bind_envelope_to_backend(binding, backend):
        raise HTTPException(502, "selected_envelope_binding_failed")

    return {
        "selected_envelope_id": envelope_id,
        "backend": backend_reported_state(),
        "model": envelope_model_evidence(envelope_id),
    }


@app.post("/administration/kyo/binds")
def administration_kyo_begin() -> Dict[str, Any]:
    """Proxy the same fixed A+B bind initialization used by Test1A."""
    result = verifier_request("POST", "/beta/bind/init", json=KYO_BIND_PAYLOAD)
    append_event(
        "kyo_ceremony_started",
        bind_id=result["bind_id"],
        participants=list(KYO_ORGANISATIONS.values()),
    )
    return result


@app.post("/administration/kyo/{organisation}/approve")
def administration_kyo_approve(
    organisation: str,
    req: KyoApprovalRequest,
) -> Dict[str, Any]:
    """Claim one phone code, verify its organization, and approve the bind."""
    expected_org = KYO_ORGANISATIONS.get(organisation)
    if expected_org is None:
        raise HTTPException(404, "unknown_kyo_organisation")
    if not req.code.isdigit() or len(req.code) != 6:
        raise HTTPException(400, "code_must_contain_exactly_six_digits")

    claim = verifier_request(
        "GET",
        "/session/claim",
        params={"code": req.code},
    )
    if claim.get("already_claimed"):
        raise HTTPException(409, "kyo_code_already_claimed")
    claimed_org = claim.get("org")
    if claimed_org != expected_org:
        append_event(
            "kyo_organisation_mismatch",
            bind_id=req.bind_id,
            expected_org=expected_org,
            claimed_org=claimed_org,
        )
        raise HTTPException(
            409,
            f"kyo_organisation_mismatch:expected={expected_org}:claimed={claimed_org}",
        )

    approval = verifier_request(
        "POST",
        "/beta/bind/approve",
        json={
            "bind_id": req.bind_id,
            "session_id": claim["session_id"],
        },
    )
    envelope_id = approval.get("envelope_id")
    append_event(
        "kyo_organisation_approved",
        bind_id=req.bind_id,
        organisation=expected_org,
        admin_cn=claim.get("admin_cn"),
        envelope_id=envelope_id,
    )
    return {
        "bind_id": req.bind_id,
        "organization": claimed_org,
        "admin_cn": claim.get("admin_cn"),
        "approval": approval,
    }


# ---------------------------------------------------------------------
# OpenHealth experiment API retained for Flower and React/Vite
# ---------------------------------------------------------------------

@app.post("/experiments/initialise")
def experiments_initialise(
    req: ExperimentInitialiseRequest,
) -> Dict[str, Any]:
    previous_run_id = experiment_state.get("run_id")
    same_run = previous_run_id == req.run_id
    preserved_envelope_id = (
        experiment_state.get("active_envelope_id") if same_run else None
    )
    preserved_backend_bound = bool(
        same_run
        and preserved_envelope_id
        and experiment_state.get("backend_bound", False)
    )

    write_experiment_config(req)
    write_participants(req.run_id)
    write_metrics_header(req.run_id)
    write_reproduce_readme(req)

    experiment_state.update(
        {
            "run_id": req.run_id,
            "status": "waiting",
            "min_clients": req.min_clients,
            "flower_server_ready": (
                backend_for_type("flower_server") is not None
            ),
            "active_envelope_id": preserved_envelope_id,
            "backend_bound": preserved_backend_bound,
        }
    )

    if previous_run_id != req.run_id:
        experiment_state["registered_clients"] = {}

    append_event(
        "experiment_initialised",
        run_id=req.run_id,
        dataset=req.dataset,
        dataset_subset=req.dataset_subset,
        rounds=req.rounds,
        min_clients=req.min_clients,
        local_epochs=req.local_epochs,
        envelope_id=preserved_envelope_id,
        envelope_binding_preserved=preserved_backend_bound,
    )

    return {
        "status": "initialised",
        "run_id": req.run_id,
        "run_dir": str(run_dir(req.run_id)),
        "active_envelope_id": preserved_envelope_id,
        "backend_bound": preserved_backend_bound,
    }


@app.get("/experiments/{run_id}")
def experiment_get(run_id: str) -> Dict[str, Any]:
    folder = run_dir(run_id)
    config_path = selected_artifact_path("experiment_config") or (
        folder / "experiment_config.json"
    )
    participants_path = selected_artifact_path("participants") or (
        folder / "participants.json"
    )

    if not config_path.exists():
        raise HTTPException(
            status_code=404,
            detail=f"Unknown run_id: {run_id}",
        )

    return {
        "run_id": run_id,
        "experiment_config": json.loads(
            config_path.read_text(encoding="utf-8")
        ),
        "participants": (
            json.loads(participants_path.read_text(encoding="utf-8"))
            if participants_path.exists()
            else None
        ),
    }


@app.get("/experiments/{run_id}/events")
def experiment_events(run_id: str, limit: int = 100) -> Dict[str, Any]:
    path = selected_artifact_path("events") or (run_dir(run_id) / "events.jsonl")
    if not path.exists():
        return {"run_id": run_id, "events": []}

    lines = path.read_text(encoding="utf-8").splitlines()
    events = [
        json.loads(line)
        for line in lines[-limit:]
        if line.strip()
    ]
    return {"run_id": run_id, "events": events}


@app.get("/experiments/{run_id}/metrics")
def experiment_metrics(run_id: str) -> Dict[str, Any]:
    model_run_id: Optional[str]
    if experiment_state.get("status") == "running":
        model_run_id = active_training_run_id()
        if model_run_id is None:
            return {
                "run_id": run_id,
                "model_run_id": None,
                "metrics": [],
            }
        path = RUNS_DIR / model_run_id / "metrics.csv"
    else:
        summary = selected_run_summary()
        model_run_id = (
            str(summary["run_id"])
            if summary and summary.get("run_id")
            else None
        )
        selected_metrics = selected_artifact_path("metrics")
        if experiment_state.get("active_envelope_id"):
            if selected_metrics is None:
                return {
                    "run_id": run_id,
                    "model_run_id": model_run_id,
                    "metrics": [],
                }
            path = selected_metrics
        else:
            path = selected_metrics or (run_dir(run_id) / "metrics.csv")

    if not path.exists():
        return {
            "run_id": run_id,
            "model_run_id": model_run_id,
            "metrics": [],
        }

    with path.open("r", encoding="utf-8") as f:
        rows: List[Dict[str, Any]] = list(csv.DictReader(f))

    return {
        "run_id": run_id,
        "model_run_id": model_run_id,
        "metrics": rows,
    }


@app.post("/clients/register")
def clients_register(req: ClientRegistration) -> Dict[str, Any]:
    if req.run_id != experiment_state.get("run_id"):
        raise HTTPException(
            status_code=409,
            detail=(
                f"Client run_id {req.run_id!r} does not match active run "
                f"{experiment_state.get('run_id')!r}"
            ),
        )

    experiment_state["registered_clients"][req.org_id] = {
        "org_id": req.org_id,
        "org_label": req.org_label,
        "data_partition": req.data_partition,
        "metadata": req.metadata,
        "registered_at": utc_now(),
    }

    append_event(
        "client_registered",
        run_id=req.run_id,
        org_id=req.org_id,
        org_label=req.org_label,
        data_partition=req.data_partition,
        metadata=req.metadata,
    )

    return {
        "status": "registered",
        "client": experiment_state["registered_clients"][req.org_id],
        "experiment": current_experiment_status(req.run_id),
    }


@app.get("/experiments/{run_id}/status")
def experiment_status(run_id: str) -> Dict[str, Any]:
    if run_id != experiment_state.get("run_id"):
        raise HTTPException(
            status_code=404,
            detail=f"Unknown run_id: {run_id}",
        )
    return current_experiment_status(run_id)


@app.post("/experiments/{run_id}/start")
def experiment_start(run_id: str) -> Dict[str, Any]:
    status_payload = experiment_status(run_id)

    if status_payload["status"] in {"running", "completed"}:
        return {
            "run_id": run_id,
            "status": status_payload["status"],
            "experiment": status_payload,
        }

    if not status_payload["flower_server_ready"]:
        raise HTTPException(
            status_code=409,
            detail="Flower server is not ready",
        )

    if not status_payload["backend_bound"]:
        raise HTTPException(
            status_code=409,
            detail="No active FLICS envelope is bound to the backend",
        )

    if (
        status_payload["registered_client_count"]
        < status_payload["min_clients"]
    ):
        raise HTTPException(
            status_code=409,
            detail=(
                "Not enough registered clients: "
                f"{status_payload['registered_client_count']} < "
                f"{status_payload['min_clients']}"
            ),
        )

    experiment_state["status"] = "running"
    append_event(
        "experiment_started",
        run_id=run_id,
        envelope_id=status_payload["active_envelope_id"],
        registered_clients=status_payload["registered_clients"],
    )

    return {
        "run_id": run_id,
        "status": "running",
        "message": "Experiment activated under the bound FLICS envelope",
        "experiment": current_experiment_status(run_id),
    }


@app.post("/experiments/{run_id}/stop")
def experiment_stop(run_id: str) -> Dict[str, Any]:
    experiment_status(run_id)
    experiment_state["status"] = "stopped"
    append_event("experiment_stopped", run_id=run_id)

    return {
        "run_id": run_id,
        "status": "stopped",
        "message": "Experiment stopped",
        "experiment": current_experiment_status(run_id),
    }


@app.post("/experiments/{run_id}/complete")
def experiment_complete(run_id: str) -> Dict[str, Any]:
    experiment_status(run_id)
    experiment_state["status"] = "completed"
    append_event("experiment_completed", run_id=run_id)

    return {
        "run_id": run_id,
        "status": "completed",
        "message": "Experiment completed",
        "experiment": current_experiment_status(run_id),
    }


@app.get("/predictions/ab/options")
def ab_prediction_options() -> Dict[str, Any]:
    return {
        "run_id": RUN_ID,
        "active_envelope_id": experiment_state.get("active_envelope_id"),
        "tissues": PATHMNIST_QUERY_TISSUES,
        "principals": [
            {
                "sub": principal,
                "organisation": context["organisation"],
                "profile": context["profile"],
                "allowed_tissues": context["allowed_tissues"],
            }
            for principal, context in AB_PRINCIPALS.items()
        ],
    }


@app.post("/predictions/ab")
def ab_prediction(req: ABPredictionRequest) -> Dict[str, Any]:
    """Run the A+B dashboard query through issuer, DPoP and Gatekeeper."""

    if req.run_id != RUN_ID:
        raise HTTPException(404, f"unknown_run:{req.run_id}")
    if req.requested_tissue not in PATHMNIST_QUERY_TISSUES:
        raise HTTPException(400, f"unknown_tissue:{req.requested_tissue}")

    active_envelope_id = experiment_state.get("active_envelope_id")
    if req.envelope_id != active_envelope_id:
        raise HTTPException(409, "envelope_is_not_active")
    if not experiment_state.get("backend_bound", False):
        raise HTTPException(409, "backend_is_not_bound")

    principal_context = AB_PRINCIPALS.get(req.principal)
    if principal_context is None:
        raise HTTPException(400, f"unknown_principal:{req.principal}")

    nonce = "nonce-" + secrets.token_urlsafe(18)
    jti = "jti-" + secrets.token_urlsafe(18)
    ect = mint_principal_ect(
        req.principal,
        principal_context,
        req.envelope_id,
    )
    dpop = sign_principal_dpop(
        req.principal,
        req.envelope_id,
        nonce,
        jti,
    )
    admission = request_prediction_admission(
        envelope_id=req.envelope_id,
        run_id=req.run_id,
        requested_tissues=[req.requested_tissue],
        jti=jti,
        authorization=f"ECT {ect}",
        dpop=dpop,
        dpop_nonce=nonce,
    )

    response: Dict[str, Any] = {
        "principal": {
            "sub": req.principal,
            "organisation": principal_context["organisation"],
            "profile": principal_context["profile"],
        },
        "request": {
            "envelope_id": req.envelope_id,
            "run_id": req.run_id,
            "requested_tissue": req.requested_tissue,
            "jti": jti,
        },
        "admission": admission,
        "executed": False,
    }
    if not admission.get("allow", False):
        return response

    try:
        backend = requests.post(
            FLOWER_BACKEND_URL + "/predict_image",
            json={
                "envelope_id": req.envelope_id,
                "run_id": req.run_id,
                "requested_tissue": req.requested_tissue,
                "topk": req.topk,
            },
            timeout=30,
        )
        backend.raise_for_status()
        prediction = backend.json()
    except Exception as exc:
        raise HTTPException(502, f"prediction_error:{exc}") from exc

    append_event(
        "image_prediction_executed",
        run_id=req.run_id,
        envelope_id=req.envelope_id,
        principal=req.principal,
        requested_tissues=[req.requested_tissue],
        jti=jti,
        image_sha256=prediction.get("image_sha256"),
    )
    response.update({"executed": True, "prediction": prediction})
    return response


@app.post("/user/inference")
def user_inference(req: UserInferenceRequest) -> Dict[str, Any]:
    """Use the Hub-held ECT for governed user inference with fresh DPoP."""
    if req.run_id != RUN_ID:
        raise HTTPException(404, f"unknown_run:{req.run_id}")
    if req.requested_tissue not in PATHMNIST_QUERY_TISSUES + ["debris"]:
        raise HTTPException(400, f"unknown_tissue:{req.requested_tissue}")

    binding_state = selected_envelope_binding_state()
    selected_id = binding_state.get("selected_envelope_id")
    if not selected_id:
        raise HTTPException(409, "no_envelope_selected")
    if req.envelope_id != selected_id:
        raise HTTPException(409, "envelope_mismatch")
    if not binding_state.get("bound", False):
        raise HTTPException(409, "envelope_not_bound")

    principal_context = AB_PRINCIPALS.get(req.principal)
    if principal_context is None:
        raise HTTPException(400, f"unknown_principal:{req.principal}")

    credential_key = principal_runtime_key(selected_id, req.principal)
    credential = holder_runtime_credentials.get(credential_key)
    if not credential:
        raise HTTPException(409, "ect_not_ready")

    expires_at = credential.get("expires_at")
    if expires_at and int(expires_at) <= int(time.time()):
        credential["expired"] = True
        raise HTTPException(409, "ect_expired")

    nonce = "nonce-" + secrets.token_urlsafe(18)
    jti = "jti-" + secrets.token_urlsafe(18)
    dpop = sign_principal_dpop(
        req.principal,
        selected_id,
        nonce,
        jti,
    )
    admission = request_prediction_admission(
        envelope_id=selected_id,
        run_id=req.run_id,
        requested_tissues=[req.requested_tissue],
        jti=jti,
        authorization=f"ECT {credential['ect']}",
        dpop=dpop,
        dpop_nonce=nonce,
    )

    model_evidence = envelope_model_evidence(selected_id)
    response: Dict[str, Any] = {
        "principal": req.principal,
        "request": {
            "envelope_id": selected_id,
            "run_id": req.run_id,
            "requested_tissue": req.requested_tissue,
            "jti": jti,
        },
        "admission": admission,
        "executed": False,
        "model_run_id": model_evidence.get("run_id"),
    }
    if not admission.get("allow", False):
        return response

    try:
        backend = requests.post(
            FLOWER_BACKEND_URL + "/predict_image",
            json={
                "envelope_id": selected_id,
                "run_id": req.run_id,
                "requested_tissue": req.requested_tissue,
                "topk": req.topk,
            },
            timeout=30,
        )
        backend.raise_for_status()
        prediction = backend.json()
    except Exception as exc:
        raise HTTPException(502, f"prediction_error:{exc}") from exc

    append_event(
        "image_prediction_executed",
        run_id=req.run_id,
        envelope_id=selected_id,
        principal=req.principal,
        requested_tissues=[req.requested_tissue],
        jti=jti,
        image_sha256=prediction.get("image_sha256"),
    )
    response.update(
        {
            "executed": True,
            "model_run_id": (
                prediction.get("run_id")
                or model_evidence.get("run_id")
            ),
            "prediction": prediction,
        }
    )
    return response


@app.post("/predict")
def predict(
    req: PredictionRequest,
    authorization: str = Header(..., alias="Authorization"),
    dpop: str = Header(..., alias="DPoP"),
    dpop_nonce: str = Header(..., alias="X-DPoP-Nonce"),
) -> Dict[str, Any]:
    """Admission first; prediction only after ALLOW."""

    if req.run_id != RUN_ID:
        raise HTTPException(404, f"unknown_run:{req.run_id}")
    if len(req.requested_tissues) != 1:
        raise HTTPException(400, "exactly_one_tissue_required")

    admission = request_prediction_admission(
        envelope_id=req.envelope_id,
        run_id=req.run_id,
        requested_tissues=req.requested_tissues,
        jti=req.jti,
        authorization=authorization,
        dpop=dpop,
        dpop_nonce=dpop_nonce,
    )
    if not admission.get("allow", False):
        return {"admission": admission, "executed": False}

    try:
        backend = requests.post(
            FLOWER_BACKEND_URL + "/predict",
            json={
                "envelope_id": req.envelope_id,
                "run_id": req.run_id,
                "requested_tissues": req.requested_tissues,
                "topk": req.topk,
            },
            timeout=30,
        )
        backend.raise_for_status()
        prediction = backend.json()
    except Exception as exc:
        raise HTTPException(502, f"prediction_error:{exc}") from exc

    append_event(
        "prediction_executed",
        envelope_id=req.envelope_id,
        requested_tissues=req.requested_tissues,
        jti=req.jti,
    )
    return {
        "admission": admission,
        "executed": True,
        "prediction": prediction,
    }


if __name__ == "__main__":
    uvicorn.run(
        "hub:app",
        host="0.0.0.0",
        port=int(os.getenv("PORT", "8080")),
    )
