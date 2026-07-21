#!/usr/bin/env python3
"""OpenHealth hub with FLICS envelope-driven coordination.

OpenHealth remains authoritative for experiment lifecycle, evidence artefacts,
client registration, and the React/Vite API contract.

FLICS remains authoritative for Redis envelope events and backend binding.
There is no pass-through governance mode and no fallback ALLOW path.
"""

from __future__ import annotations

import asyncio
import csv
import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

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
        "status": experiment_state.get("status", "waiting"),
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
# OpenHealth experiment API retained for Flower and React/Vite
# ---------------------------------------------------------------------

@app.post("/experiments/initialise")
def experiments_initialise(
    req: ExperimentInitialiseRequest,
) -> Dict[str, Any]:
    previous_run_id = experiment_state.get("run_id")

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
            "active_envelope_id": None,
            "backend_bound": False,
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
    )

    return {
        "status": "initialised",
        "run_id": req.run_id,
        "run_dir": str(run_dir(req.run_id)),
    }


@app.get("/experiments/{run_id}")
def experiment_get(run_id: str) -> Dict[str, Any]:
    folder = run_dir(run_id)
    config_path = folder / "experiment_config.json"
    participants_path = folder / "participants.json"

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
    path = run_dir(run_id) / "events.jsonl"
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
    path = run_dir(run_id) / "metrics.csv"
    if not path.exists():
        return {"run_id": run_id, "metrics": []}

    with path.open("r", encoding="utf-8") as f:
        rows: List[Dict[str, Any]] = list(csv.DictReader(f))

    return {"run_id": run_id, "metrics": rows}


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

    admission_request = {
        "envelope_id": req.envelope_id,
        "run_id": req.run_id,
        "resource": "pathmnist-colon-pathology",
        "action": "query_model",
        "purpose": "approved_model_query",
        "requested_tissues": req.requested_tissues,
        "jti": req.jti,
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
        envelope_id=req.envelope_id,
        requested_tissues=req.requested_tissues,
        jti=req.jti,
        **admission,
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
