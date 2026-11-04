#!/usr/bin/env python3
"""OpenHealth Flower coordinator for the PathMNIST A+B and Mode 1A workloads.

The existing governance boundary is preserved:
- Hub controls experiment activation.
- The backend accepts a Hub-approved envelope binding.
- Flower training starts only after the Hub marks the run as ``running``.

Mode 1A admits Hospital C only after Charlie receives a run-bound sponsored-
guest contribution ALLOW for the actual Flower run.
"""

from __future__ import annotations

import base64
import binascii
import io
import csv
import hashlib
import hmac
import json
import os
import re
import socket
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import flwr as fl
import numpy as np
import requests
import torch
import uvicorn
from fastapi import FastAPI, Header, HTTPException
from flwr.common import (
    Metrics,
    Parameters,
    ndarrays_to_parameters,
    parameters_to_ndarrays,
)
from flwr.server.client_manager import SimpleClientManager
from flwr.server.client_proxy import ClientProxy
from flwr.server.strategy import FedAvg
from PIL import Image, UnidentifiedImageError
from pydantic import BaseModel, Field

from admission import (
    AdmissionThresholdNotMet,
    EnvelopeExpired,
    admission_keys,
    admit,
    envelope_expired,
)
from workloads.active import (
    ACTIVE_CLASSES,
    CLASS_NAMES,
    DEVICE,
    IGNORED_CLASSES,
    Net,
    PATHMNIST_PARTITION_PROFILE,
    PATHMNIST_PARTITION_SEED,
    STORY_CANCER_CLASSES,
    STORY_NON_CANCER_CLASSES,
    evaluate_full_test,
    get_parameters,
    labels_array,
    load_test_dataset,
    make_test_loader,
    seed_everything,
    set_parameters,
    transform,
)

# ---------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------

HUB_URL = os.getenv("HUB_URL", "http://fc-hub:8080").rstrip("/")
RUN_ID = os.getenv("RUN_ID", "local-pathmnist-ab-001")
RUNS_DIR = Path(os.getenv("RUNS_DIR", "/vault/runs"))
VAULT_ROOT = Path(os.getenv("VAULT_ROOT", "/vault"))
SERVER_ADDRESS = os.getenv("SERVER_ADDRESS", "0.0.0.0:8080")
SERVER_POLL_SECONDS = float(os.getenv("SERVER_POLL_SECONDS", "1"))

CONTROL_HOST = os.getenv("CONTROL_HOST", "0.0.0.0")
CONTROL_PORT = int(os.getenv("CONTROL_PORT", "8081"))


def load_control_token() -> str:
    """Issue #7: the token the hub presents on /bind_envelope, from FLOWER_CONTROL_TOKEN
    (ECS secret) or a read-only mounted file (FLOWER_CONTROL_TOKEN_FILE, L0)."""
    value = os.getenv("FLOWER_CONTROL_TOKEN", "").strip()
    path = os.getenv("FLOWER_CONTROL_TOKEN_FILE", "")
    if value or not path:
        return value
    try:
        return Path(path).read_text(encoding="utf-8").strip()
    except OSError:
        return ""


CONTROL_TOKEN = load_control_token()
BACKEND_ID = os.getenv("BACKEND_ID", "flower-local")
BACKEND_TYPE = os.getenv("BACKEND_TYPE", "flower_server")
BACKEND_URL = os.getenv(
    "BACKEND_URL",
    f"http://flower-server:{CONTROL_PORT}",
).rstrip("/")
BACKEND_REGISTER_SECONDS = float(
    os.getenv("BACKEND_REGISTER_SECONDS", "2")
)
COMPLETION_RETRY_SECONDS = float(
    os.getenv("COMPLETION_RETRY_SECONDS", "2")
)

DEFAULT_ROUNDS = int(
    os.getenv("FLOWER_ROUNDS", os.getenv("NUM_ROUNDS", "10"))
)
DEFAULT_MIN_CLIENTS = int(
    os.getenv("MIN_CLIENTS", os.getenv("MIN_AVAILABLE_CLIENTS", "2"))
)
DEFAULT_FRACTION_FIT = float(os.getenv("FRACTION_FIT", "1.0"))
# Issue #7: how long a round waits for enough admitted clients to prove
# their identity before it fails closed.
ADMISSION_TIMEOUT_SECONDS = float(os.getenv("ADMISSION_TIMEOUT_SECONDS", "120"))
ADMISSION_RETRY_SECONDS = 5.0
# A sampled client that never answers must not hold a round open for ever.
ROUND_TIMEOUT_SECONDS = float(os.getenv("ROUND_TIMEOUT_SECONDS", "600"))
# How long a round waits for enough clients to connect (Flower's own wait is 24 h),
# so a required hospital that never connects fails the run in bounded time. Longer
# than a client start on ECS (about 3 minutes, mostly the image pull).
CLIENT_WAIT_TIMEOUT_SECONDS = float(os.getenv("CLIENT_WAIT_TIMEOUT_SECONDS", "300"))
MODE1A_TRAINING_MIN_CLIENTS = 3
MODE1A_GUEST_PRINCIPAL = "Charlie"
MODE1A_GUEST_TISSUES = [
    "adipose",
    "debris",
    "lymphocytes",
    "mucus",
    "smooth_muscle",
    "normal_colon_mucosa",
    "cancer_associated_stroma",
    "colorectal_adenocarcinoma_epithelium",
]
GUEST_ADMISSION_RETRY_SECONDS = 2.0

# ---------------------------------------------------------------------
# Runtime state and control plane
# ---------------------------------------------------------------------

control_app = FastAPI(title="OpenHealth Flower backend control plane")
bound_envelope: Optional[Dict[str, Any]] = None
bound_envelope_lock = threading.Lock()
active_artifact_run_id: Optional[str] = None
artifact_run_lock = threading.Lock()

# One recall column per cancer class (class_7 and class_8 for PathMNIST).
CANCER_CLASS_RECALL_KEYS = [
    f"class_{label}_recall" for label in STORY_CANCER_CLASSES
]


def cancer_class_recalls(per_class_recall: List[float]) -> Dict[str, float]:
    return {
        f"class_{label}_recall": per_class_recall[label]
        for label in STORY_CANCER_CLASSES
    }


training_state: Dict[str, Any] = {
    "status": "waiting",
    "phase": None,
    "data_partition_profile": PATHMNIST_PARTITION_PROFILE,
    "data_partition_seed": PATHMNIST_PARTITION_SEED,
    "round": 0,
    "rounds": DEFAULT_ROUNDS,
    "min_clients": DEFAULT_MIN_CLIENTS,
    "guest_admission_decision_id": None,
    "guest_admission_run_id": None,
    "overall_accuracy": None,
    "macro_recall": None,
    "non_cancer_recall": None,
    "cancer_recall": None,
    "cancer_f1": None,
    **{key: None for key in CANCER_CLASS_RECALL_KEYS},
    "error": None,
}
training_state_lock = threading.Lock()


class EnvelopeBinding(BaseModel):
    envelope_id: str
    policy_hash: Optional[str] = None
    valid_until: int  # issue #7: only a bounded envelope can be bound
    participants: List[str] = Field(default_factory=list)
    # Issue #7: org_id -> public Flower execution key (Ed25519, base64url),
    # resolved by the Hub from each admitted organisation's issuer.
    participant_keys: Dict[str, str] = Field(default_factory=dict)
    # Mode 1A: sponsored guest organisation -> public execution key, registered by
    # the sponsor's issuer. Used only after the guest's contribution is admitted.
    guest_keys: Dict[str, str] = Field(default_factory=dict)


class PredictionRequest(BaseModel):
    envelope_id: str
    run_id: str
    requested_tissues: List[str]
    topk: int = Field(default=3, ge=1, le=9)


class ImagePredictionRequest(BaseModel):
    envelope_id: str
    run_id: str
    image_b64: Optional[str] = None
    requested_tissue: Optional[str] = None
    filename: Optional[str] = None
    topk: int = Field(default=3, ge=1, le=9)


PATHMNIST_TISSUES = (
    "adipose", "background", "debris", "lymphocytes", "mucus",
    "smooth_muscle", "normal_colon_mucosa",
    "cancer_associated_stroma",
    "colorectal_adenocarcinoma_epithelium",
)

MAX_IMAGE_BYTES = 5 * 1024 * 1024


def class_recall_from_confusion(tissue: Optional[str]) -> Optional[float]:
    if not tissue:
        return None

    try:
        label = PATHMNIST_TISSUES.index(tissue)
    except ValueError:
        return None

    path = confusion_normalized_path()
    if not path.is_file():
        return None

    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.reader(handle)
        next(reader, None)

        for row in reader:
            if not row:
                continue

            try:
                row_label = int(row[0].split(":", 1)[0])
            except (ValueError, IndexError):
                continue

            if row_label == label:
                try:
                    return float(row[label + 1])
                except (ValueError, IndexError):
                    return None

    return None

def model_dict(model: BaseModel) -> Dict[str, Any]:
    if hasattr(model, "model_dump"):
        return model.model_dump()  # type: ignore[attr-defined]
    return model.dict()


def update_training_state(**values: Any) -> None:
    with training_state_lock:
        training_state.update(values)


@control_app.get("/health")
def control_health() -> Dict[str, Any]:
    with bound_envelope_lock:
        envelope_id = (
            bound_envelope.get("envelope_id")
            if bound_envelope is not None
            else None
        )
    return {
        "status": "ok",
        "backend_id": BACKEND_ID,
        "backend_type": BACKEND_TYPE,
        "run_id": RUN_ID,
        "bound_envelope_id": envelope_id,
    }


@control_app.get("/status")
def control_status() -> Dict[str, Any]:
    with bound_envelope_lock:
        envelope = dict(bound_envelope) if bound_envelope else None
    with training_state_lock:
        training = dict(training_state)
    return {
        "backend_id": BACKEND_ID,
        "run_id": RUN_ID,
        "model_run_id": current_artifact_run_id(),
        "bound_envelope": envelope,
        "training": training,
    }


def require_control_token(presented: Any) -> None:
    """The binding sets the keys admission trusts, so only the hub may make it.
    Fails closed: without a configured token nothing can bind."""
    if not CONTROL_TOKEN:
        raise HTTPException(503, "control_token_not_configured")
    presented = presented if isinstance(presented, str) else ""
    if not hmac.compare_digest(presented.encode("utf-8"), CONTROL_TOKEN.encode("utf-8")):
        raise HTTPException(401, "invalid_control_token")


@control_app.post("/bind_envelope")
def bind_envelope(
    binding: EnvelopeBinding,
    x_openhealth_control_token: str = Header(default=""),
) -> Dict[str, Any]:
    """Record a Hub-approved binding without starting Flower training."""

    global bound_envelope, active_artifact_run_id

    require_control_token(x_openhealth_control_token)

    payload = model_dict(binding)
    payload["bound_at"] = utc_now()

    with bound_envelope_lock:
        bound_envelope = payload

    manifest_path = VAULT_ROOT / binding.envelope_id / "run.json"
    latest_run_id = None
    if manifest_path.is_file():
        try:
            latest_run_id = json.loads(
                manifest_path.read_text(encoding="utf-8")
            ).get("run_id")
        except (OSError, ValueError):
            latest_run_id = None
    with artifact_run_lock:
        active_artifact_run_id = str(latest_run_id) if latest_run_id else None

    envelope_root = VAULT_ROOT / binding.envelope_id
    envelope_root.mkdir(parents=True, exist_ok=True)
    (envelope_root / "bound_envelope.json").write_text(
        json.dumps(payload, indent=2),
        encoding="utf-8",
    )
    write_event(
        "envelope_bound",
        envelope_id=binding.envelope_id,
        policy_hash=binding.policy_hash,
        participants=binding.participants,
    )
    return {
        "status": "bound",
        "backend_id": BACKEND_ID,
        "run_id": RUN_ID,
        "envelope_id": binding.envelope_id,
        "model_run_id": latest_run_id,
    }


@control_app.post("/predict")
def predict(req: PredictionRequest) -> Dict[str, Any]:
    """Predict one backend-selected PathMNIST test sample."""

    if req.run_id != RUN_ID:
        raise HTTPException(404, f"unknown_run:{req.run_id}")
    if len(req.requested_tissues) != 1:
        raise HTTPException(400, "exactly_one_tissue_required")

    tissue = req.requested_tissues[0]
    try:
        requested_label = PATHMNIST_TISSUES.index(tissue)
    except ValueError as exc:
        raise HTTPException(400, f"unknown_tissue:{tissue}") from exc

    if requested_label in IGNORED_CLASSES:
        raise HTTPException(403, "reserved_tissue")

    model_path = checkpoint_path()
    if not model_path.is_file():
        raise HTTPException(409, "model_not_ready")

    model = Net().to(DEVICE)
    state = torch.load(model_path, map_location=DEVICE)
    if isinstance(state, dict) and "model_state_dict" in state:
        state = state["model_state_dict"]
    model.load_state_dict(state)
    model.eval()

    dataset = load_test_dataset()
    labels = labels_array(dataset)
    sample_index = int(np.flatnonzero(labels == requested_label)[0])
    image, actual = dataset[sample_index]

    with torch.no_grad():
        probabilities = torch.softmax(
            model(image.unsqueeze(0).to(DEVICE)),
            dim=1,
        )[0]

    values, predicted = torch.topk(probabilities, k=req.topk)
    prediction_label = int(predicted[0].item())
    result = {
        "run_id": current_artifact_run_id() or RUN_ID,
        "envelope_id": req.envelope_id,
        "requested_tissue": tissue,
        "sample_index": sample_index,
        "actual_label": int(np.asarray(actual).reshape(-1)[0]),
        "prediction_label": prediction_label,
        "prediction_tissue": PATHMNIST_TISSUES[prediction_label],
        "topk": [
            {
                "label": int(label.item()),
                "tissue": PATHMNIST_TISSUES[int(label.item())],
                "probability": float(value.item()),
            }
            for value, label in zip(values, predicted)
        ],
    }
    write_event(
        "prediction_completed",
        envelope_id=req.envelope_id,
        requested_tissue=tissue,
        prediction_label=prediction_label,
    )
    return result


@control_app.post("/predict_image")
def predict_image(req: ImagePredictionRequest) -> Dict[str, Any]:
    """Predict a caller image or a deterministic governed PathMNIST sample.

    This is an internal inference endpoint. Admission remains the Hub and
    Gatekeeper responsibility.
    """

    if req.run_id != RUN_ID:
        raise HTTPException(404, f"unknown_run:{req.run_id}")

    sample_index: Optional[int] = None
    actual_label: Optional[int] = None
    requested_tissue = req.requested_tissue

    if req.image_b64:
        encoded = req.image_b64.strip()
        if encoded.startswith("data:"):
            if "," not in encoded:
                raise HTTPException(400, "invalid_image_data_url")
            encoded = encoded.split(",", 1)[1]

        try:
            raw_image = base64.b64decode(encoded, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise HTTPException(400, "invalid_image_base64") from exc

        if not raw_image:
            raise HTTPException(400, "empty_image")
        if len(raw_image) > MAX_IMAGE_BYTES:
            raise HTTPException(413, "image_too_large")

        try:
            with Image.open(io.BytesIO(raw_image)) as source:
                source.load()
                original_width, original_height = source.size
                original_mode = source.mode
                image = source.convert("RGB").resize((28, 28))
        except (UnidentifiedImageError, OSError, ValueError) as exc:
            raise HTTPException(400, "invalid_image") from exc
        image_tensor = transform()(image).unsqueeze(0).to(DEVICE)
        filename = req.filename
        input_source = "caller_image"
    else:
        if not requested_tissue:
            raise HTTPException(400, "image_or_requested_tissue_required")
        try:
            requested_label = PATHMNIST_TISSUES.index(requested_tissue)
        except ValueError as exc:
            raise HTTPException(
                400,
                f"unknown_tissue:{requested_tissue}",
            ) from exc
        if requested_label in IGNORED_CLASSES:
            raise HTTPException(403, "reserved_tissue")

        dataset = load_test_dataset()
        labels = labels_array(dataset)
        sample_index = int(np.flatnonzero(labels == requested_label)[0])
        dataset_image, actual = dataset[sample_index]
        actual_label = int(np.asarray(actual).reshape(-1)[0])
        image_tensor = dataset_image.unsqueeze(0).to(DEVICE)

        preview_array = (
            dataset_image.detach()
            .cpu()
            .permute(1, 2, 0)
            .mul(0.5)
            .add(0.5)
            .clamp(0, 1)
            .mul(255)
            .to(torch.uint8)
            .numpy()
        )
        image = Image.fromarray(preview_array, mode="RGB")
        original_width, original_height = image.size
        original_mode = image.mode
        filename = req.filename or f"pathmnist-test-{sample_index}.png"
        input_source = "governed_test_sample"

    preview_buffer = io.BytesIO()
    image.save(preview_buffer, format="PNG")
    preview_bytes = preview_buffer.getvalue()
    image_sha256 = hashlib.sha256(preview_bytes).hexdigest()

    model_path = checkpoint_path()
    if not model_path.is_file():
        raise HTTPException(409, "model_not_ready")

    model = Net().to(DEVICE)
    state = torch.load(model_path, map_location=DEVICE)
    if isinstance(state, dict) and "model_state_dict" in state:
        state = state["model_state_dict"]
    model.load_state_dict(state)
    model.eval()

    with torch.no_grad():
        probabilities = torch.softmax(model(image_tensor), dim=1)[0]

    values, predicted = torch.topk(probabilities, k=req.topk)
    prediction_label = int(predicted[0].item())
    result = {
        "run_id": current_artifact_run_id() or RUN_ID,
        "envelope_id": req.envelope_id,
        "filename": filename,
        "requested_tissue": requested_tissue,
        "sample_index": sample_index,
        "actual_label": actual_label,
        "image_sha256": image_sha256,
        "sample_image": {
            "mime_type": "image/png",
            "image_b64": base64.b64encode(preview_bytes).decode("ascii"),
            "width": 28,
            "height": 28,
        },
        "input_image": {
            "source": input_source,
            "original_width": original_width,
            "original_height": original_height,
            "original_mode": original_mode,
            "model_width": 28,
            "model_height": 28,
            "model_mode": "RGB",
        },
        "class_recall": class_recall_from_confusion(requested_tissue),
        "prediction_label": prediction_label,
        "prediction_tissue": PATHMNIST_TISSUES[prediction_label],
        "topk": [
            {
                "label": int(label.item()),
                "tissue": PATHMNIST_TISSUES[int(label.item())],
                "probability": float(value.item()),
            }
            for value, label in zip(values, predicted)
        ],
    }
    write_event(
        "image_prediction_completed",
        envelope_id=req.envelope_id,
        filename=filename,
        requested_tissue=requested_tissue,
        sample_index=sample_index,
        image_sha256=image_sha256,
        prediction_label=prediction_label,
    )
    return result


def start_control_plane() -> threading.Thread:
    thread = threading.Thread(
        target=uvicorn.run,
        kwargs={
            "app": control_app,
            "host": CONTROL_HOST,
            "port": CONTROL_PORT,
            "log_level": "warning",
        },
        name="flower-control-plane",
        daemon=True,
    )
    thread.start()
    return thread


def wait_for_control_plane() -> None:
    while True:
        try:
            with socket.create_connection(
                ("127.0.0.1", CONTROL_PORT),
                timeout=1,
            ):
                return
        except OSError:
            time.sleep(0.1)


# ---------------------------------------------------------------------
# Evidence and artifact paths
# ---------------------------------------------------------------------

def control_run_dir() -> Path:
    path = RUNS_DIR / RUN_ID
    path.mkdir(parents=True, exist_ok=True)
    return path


def current_artifact_run_id() -> Optional[str]:
    with artifact_run_lock:
        return active_artifact_run_id


def run_dir() -> Path:
    run_id = current_artifact_run_id()
    if not run_id:
        return control_run_dir()
    path = RUNS_DIR / run_id
    path.mkdir(parents=True, exist_ok=True)
    return path


def allocate_training_run() -> str:
    global active_artifact_run_id

    session_id = current_session_id()
    if not session_id:
        raise RuntimeError("Cannot allocate a run without a bound envelope")

    match = re.fullmatch(r"(.*-)(\d+)", RUN_ID)
    if match is None:
        raise RuntimeError(f"RUN_ID lacks numeric suffix: {RUN_ID}")
    prefix, initial_digits = match.groups()
    width = len(initial_digits)
    initial_number = int(initial_digits)
    numbers = []
    RUNS_DIR.mkdir(parents=True, exist_ok=True)
    for candidate in RUNS_DIR.iterdir():
        if not candidate.is_dir():
            continue
        candidate_match = re.fullmatch(
            re.escape(prefix) + r"(\d+)",
            candidate.name,
        )
        if candidate_match and (
            candidate.name != RUN_ID
            or (candidate / "run_allocation.json").exists()
            or (candidate / "final_model_metadata.json").exists()
            or (candidate / "model.pt").exists()
        ):
            numbers.append(int(candidate_match.group(1)))

    next_number = max(numbers, default=initial_number - 1) + 1
    run_id = f"{prefix}{next_number:0{width}d}"
    with artifact_run_lock:
        active_artifact_run_id = run_id
    (RUNS_DIR / run_id).mkdir(
        parents=True,
        exist_ok=(run_id == RUN_ID),
    )
    (RUNS_DIR / run_id / "run_allocation.json").write_text(
        json.dumps(
            {
                "run_id": run_id,
                "session_id": session_id,
                "allocated_at": utc_now(),
            },
            indent=2,
        ),
        encoding="utf-8",
    )
    return run_id


def events_path() -> Path:
    return run_dir() / "events.jsonl"


def metrics_path() -> Path:
    return run_dir() / "metrics.csv"


def participants_path() -> Path:
    return run_dir() / "participants.json"


def experiment_config_path() -> Path:
    return control_run_dir() / "experiment_config.json"


def checkpoint_path() -> Path:
    return run_dir() / "model.pt"


def confusion_counts_path() -> Path:
    return run_dir() / "confusion_counts.csv"


def confusion_normalized_path() -> Path:
    return run_dir() / "confusion_normalized.csv"


def class_metrics_path() -> Path:
    return run_dir() / "class_metrics.csv"


def final_model_metadata_path() -> Path:
    return run_dir() / "final_model_metadata.json"


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def json_safe(value: Any) -> Any:
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, dict):
        return {
            str(key): json_safe(item)
            for key, item in value.items()
        }
    if isinstance(value, (list, tuple, set)):
        return [json_safe(item) for item in value]
    return str(value)


def write_event(event_type: str, **kwargs: Any) -> None:
    event = {
        "timestamp": utc_now(),
        "run_id": current_artifact_run_id() or RUN_ID,
        "component": "vfp-core/flower_server",
        "event_type": event_type,
        **kwargs,
    }
    with events_path().open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(json_safe(event)) + "\n")


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def current_session_id() -> Optional[str]:
    with bound_envelope_lock:
        if not bound_envelope:
            return None
        return str(bound_envelope.get("envelope_id"))


# ---------------------------------------------------------------------
# Hub registration and lifecycle
# ---------------------------------------------------------------------

def register_with_hub() -> None:
    payload = {
        "backend_id": BACKEND_ID,
        "backend_type": BACKEND_TYPE,
        "url": BACKEND_URL,
        "metadata": {
            "run_id": RUN_ID,
            "server_address": SERVER_ADDRESS,
            "rounds": DEFAULT_ROUNDS,
            "min_clients": DEFAULT_MIN_CLIENTS,
            "central_evaluation": True,
            "data_partition_profile": PATHMNIST_PARTITION_PROFILE,
            "data_partition_seed": PATHMNIST_PARTITION_SEED,
        },
    }

    while True:
        try:
            response = requests.post(
                f"{HUB_URL}/backend/register",
                json=payload,
                timeout=15,
            )
            response.raise_for_status()
            write_event(
                "backend_registered_with_hub",
                backend_id=BACKEND_ID,
                backend_url=BACKEND_URL,
            )
            return
        except Exception as exc:
            write_event(
                "backend_registration_failed",
                error=str(exc),
                retry_seconds=BACKEND_REGISTER_SECONDS,
            )
            time.sleep(BACKEND_REGISTER_SECONDS)


def wait_for_experiment_start() -> Dict[str, Any]:
    write_event(
        "server_waiting_for_start",
        hub_url=HUB_URL,
        poll_seconds=SERVER_POLL_SECONDS,
    )
    last_status: Optional[str] = None

    while True:
        try:
            response = requests.get(
                f"{HUB_URL}/experiments/{RUN_ID}/status",
                timeout=5,
            )
            response.raise_for_status()
            status = response.json()
            current_status = str(status.get("status", "unknown"))

            if current_status != last_status:
                write_event(
                    "experiment_status_changed",
                    status=current_status,
                    registered_client_count=status.get(
                        "registered_client_count"
                    ),
                    min_clients=status.get("min_clients"),
                    can_start=status.get("can_start"),
                )
                last_status = current_status

            if current_status == "running":
                write_event(
                    "server_activation_received",
                    experiment_status=status,
                )
                return status

            if current_status in {"completed", "failed"}:
                return status
        except Exception as exc:
            write_event(
                "server_activation_poll_error",
                error=str(exc),
            )

        time.sleep(SERVER_POLL_SECONDS)


def notify_hub_finished(error: Optional[str] = None) -> None:
    """Report the end of the run: /complete, or /fail with the reason. Issue #7: a
    failed run is never reported to the hub as completed."""
    outcome = "fail" if error else "complete"
    while True:
        try:
            response = requests.post(
                f"{HUB_URL}/experiments/{RUN_ID}/{outcome}",
                json={"error": error} if error else None,
                timeout=5,
            )
            response.raise_for_status()
            write_event(
                "hub_completion_notified",
                outcome=outcome,
                response=response.json(),
            )
            return
        except Exception as exc:
            write_event(
                "hub_completion_notify_failed",
                outcome=outcome,
                error=str(exc),
                retry_seconds=COMPLETION_RETRY_SECONDS,
            )
            time.sleep(COMPLETION_RETRY_SECONDS)


def keep_control_plane_alive() -> None:
    """Remain queryable, then restart cleanly when another START arrives."""
    write_event("server_control_plane_idle")
    while True:
        try:
            response = requests.get(
                f"{HUB_URL}/experiments/{RUN_ID}/status",
                timeout=5,
            )
            response.raise_for_status()
            if response.json().get("status") == "running":
                os.execv(sys.executable, [sys.executable, *sys.argv])
        except Exception as exc:
            write_event("server_restart_poll_error", error=str(exc))
        time.sleep(SERVER_POLL_SECONDS)


class GuestAdmissionDenied(RuntimeError):
    """The Gatekeeper denied the Mode 1A guest contribution, or the hub refused the request."""


def require_mode1a_guest_admission(
    run_id: str,
    phase: str,
) -> Optional[Dict[str, Any]]:
    """Gate Mode 1A training before the Flower gRPC server is opened.

    Issue #7: a DENY, or a request the hub refuses, raises GuestAdmissionDenied, so the run
    fails through report_failed_run() (the hub says 'failed', the server goes idle). A hub or
    Gatekeeper that is unavailable or not ready yet (no answer, 409, 5xx) is retried."""

    if phase != "MODE1A":
        return None

    envelope_id = current_session_id()
    if not envelope_id:
        raise RuntimeError("Mode 1A admission requires a bound envelope")
    if not MODE1A_GUEST_PRINCIPAL:
        raise RuntimeError("MODE1A_GUEST_PRINCIPAL must not be empty")

    while True:
        try:
            response = requests.post(
                f"{HUB_URL}/mode1a/guest/contribution/admission",
                json={
                    "principal": MODE1A_GUEST_PRINCIPAL,
                    "envelope_id": envelope_id,
                    "run_id": run_id,
                    "requested_tissues": MODE1A_GUEST_TISSUES,
                },
                timeout=15,
            )
        except Exception as exc:
            write_event(
                "guest_contribution_admission_unavailable",
                principal=MODE1A_GUEST_PRINCIPAL,
                envelope_id=envelope_id,
                admission_run_id=run_id,
                error=str(exc),
            )
            time.sleep(GUEST_ADMISSION_RETRY_SECONDS)
            continue

        if response.status_code == 409 or response.status_code >= 500:
            write_event(
                "guest_contribution_admission_wait",
                principal=MODE1A_GUEST_PRINCIPAL,
                envelope_id=envelope_id,
                admission_run_id=run_id,
                http_status=response.status_code,
                detail=response.text,
            )
            time.sleep(GUEST_ADMISSION_RETRY_SECONDS)
            continue

        if not response.ok:
            error = (
                "Mode 1A guest admission request failed: "
                f"HTTP {response.status_code} {response.text}"
            )
            update_training_state(status="admission_error", error=error)
            write_event(
                "guest_contribution_admission_error",
                principal=MODE1A_GUEST_PRINCIPAL,
                envelope_id=envelope_id,
                admission_run_id=run_id,
                error=error,
            )
            raise GuestAdmissionDenied(error)

        result = response.json()
        admission = result.get("admission") or {}
        if not admission.get("allow", False):
            reason = str(admission.get("reason") or "admission_denied")
            update_training_state(
                status="admission_denied",
                error=reason,
                guest_admission_decision_id=admission.get("decision_id"),
                guest_admission_run_id=run_id,
            )
            write_event(
                "guest_contribution_denied",
                principal=MODE1A_GUEST_PRINCIPAL,
                envelope_id=envelope_id,
                admission_run_id=run_id,
                decision_id=admission.get("decision_id"),
                reason=reason,
            )
            raise GuestAdmissionDenied(f"Mode 1A guest contribution denied: {reason}")

        decision_id = admission.get("decision_id")
        write_event(
            "guest_contribution_admitted",
            principal=MODE1A_GUEST_PRINCIPAL,
            envelope_id=envelope_id,
            admission_run_id=run_id,
            decision_id=decision_id,
        )
        update_training_state(
            guest_admission_decision_id=decision_id,
            guest_admission_run_id=run_id,
        )
        return result


# ---------------------------------------------------------------------
# Experiment configuration
# ---------------------------------------------------------------------

def fetch_experiment_config_from_hub() -> Optional[Dict[str, Any]]:
    try:
        response = requests.get(
            f"{HUB_URL}/experiments/{RUN_ID}",
            timeout=5,
        )
        response.raise_for_status()
        payload = response.json()
        config = payload.get("experiment_config")
        if not isinstance(config, dict):
            raise ValueError("Hub response lacks experiment_config")
        experiment_config_path().write_text(
            json.dumps(config, indent=2),
            encoding="utf-8",
        )
        return config
    except Exception as exc:
        write_event("experiment_config_fetch_failed", error=str(exc))
        return None


def load_experiment_config() -> Dict[str, Any]:
    path = experiment_config_path()
    if path.exists():
        try:
            config = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(config, dict):
                return config
        except Exception as exc:
            write_event("experiment_config_read_failed", error=str(exc))

    fetched = fetch_experiment_config_from_hub()
    if fetched is not None:
        return fetched

    return {
        "run_id": RUN_ID,
        "dataset": "medmnist",
        "dataset_subset": "pathmnist",
        "aggregation_strategy": "FedAvg",
        "rounds": DEFAULT_ROUNDS,
        "min_clients": DEFAULT_MIN_CLIENTS,
        "fraction_fit": DEFAULT_FRACTION_FIT,
    }


def positive_int(
    config: Dict[str, Any],
    key: str,
    default: int,
) -> int:
    try:
        return max(1, int(config.get(key, default)))
    except (TypeError, ValueError):
        return default


def bounded_fraction(
    config: Dict[str, Any],
    key: str,
    default: float,
) -> float:
    try:
        value = float(config.get(key, default))
    except (TypeError, ValueError):
        return default
    return value if 0.0 < value <= 1.0 else default


# ---------------------------------------------------------------------
# Metrics and diagnostics
# ---------------------------------------------------------------------

def weighted_metric(
    metrics: List[Tuple[int, Metrics]],
    key: str,
) -> Optional[float]:
    total_examples = 0
    weighted_sum = 0.0

    for num_examples, values in metrics:
        value = values.get(key)
        if value is None:
            continue
        total_examples += num_examples
        weighted_sum += num_examples * float(value)

    if total_examples == 0:
        return None
    return weighted_sum / total_examples


def fit_metrics_aggregation_fn(
    metrics: List[Tuple[int, Metrics]],
) -> Metrics:
    result: Metrics = {}
    for key in ("train_loss", "train_accuracy"):
        value = weighted_metric(metrics, key)
        if value is not None:
            result[key] = value
    return result


def ensure_metrics_header() -> None:
    with metrics_path().open("w", newline="", encoding="utf-8") as handle:
        csv.writer(handle).writerow(
            [
                "run_id",
                "session_id",
                "phase",
                "round",
                "client_count",
                "failure_count",
                "train_loss",
                "train_accuracy",
                "loss",
                "accuracy",
                "macro_recall",
                "non_cancer_recall",
                "cancer_recall",
                "cancer_f1",
                *CANCER_CLASS_RECALL_KEYS,
            ]
        )


def save_confusion_matrix(
    path: Path,
    confusion: np.ndarray,
    *,
    normalized: bool,
) -> None:
    if normalized:
        row_totals = confusion.sum(axis=1, keepdims=True)
        matrix = confusion.astype(float) / row_totals.clip(min=1)
    else:
        matrix = confusion

    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            ["true\\predicted"]
            + [
                f"{index}:{name}"
                for index, name in enumerate(CLASS_NAMES)
            ]
        )
        for index, row in enumerate(matrix):
            values = (
                [f"{float(value):.6f}" for value in row]
                if normalized
                else [int(value) for value in row]
            )
            writer.writerow(
                [f"{index}:{CLASS_NAMES[index]}", *values]
            )


def save_class_metrics(
    path: Path,
    metrics: List[Dict[str, float]],
) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            [
                "class_id",
                "class_name",
                "support",
                "predicted",
                "true_positive",
                "precision",
                "recall",
                "f1",
                "top_wrong_label",
                "top_wrong_name",
                "top_wrong_count",
            ]
        )

        for values in metrics:
            class_id = int(values["class_id"])
            top_wrong_label = int(values["top_wrong_label"])
            writer.writerow(
                [
                    class_id,
                    CLASS_NAMES[class_id],
                    int(values["support"]),
                    int(values["predicted"]),
                    int(values["true_positive"]),
                    f'{values["precision"]:.6f}',
                    f'{values["recall"]:.6f}',
                    f'{values["f1"]:.6f}',
                    top_wrong_label,
                    CLASS_NAMES[top_wrong_label],
                    int(values["top_wrong_count"]),
                ]
            )


def story_metrics(
    class_metrics: List[Dict[str, float]],
) -> Dict[str, float]:
    by_class = {
        int(values["class_id"]): values
        for values in class_metrics
    }

    non_cancer_recall = float(
        np.mean(
            [
                by_class[label]["recall"]
                for label in STORY_NON_CANCER_CLASSES
            ]
        )
    )
    cancer_recall = float(
        np.mean(
            [
                by_class[label]["recall"]
                for label in STORY_CANCER_CLASSES
            ]
        )
    )
    cancer_f1 = float(
        np.mean(
            [
                by_class[label]["f1"]
                for label in STORY_CANCER_CLASSES
            ]
        )
    )

    return {
        "non_cancer_recall": non_cancer_recall,
        "cancer_recall": cancer_recall,
        "cancer_f1": cancer_f1,
    }


# ---------------------------------------------------------------------
# Evidence-aware FedAvg with central evaluation
# ---------------------------------------------------------------------

class BoundedClientManager(SimpleClientManager):
    """Issue #7: Flower waits up to 24 h for enough clients to connect before it
    samples a round. Bounded here, so a missing hospital fails the round instead."""

    def wait_for(self, num_clients: int, timeout: int = 86400) -> bool:
        return super().wait_for(
            num_clients,
            min(timeout, CLIENT_WAIT_TIMEOUT_SECONDS),
        )


class CleanStopServer(fl.server.Server):
    """Issue #7: an error during the run ends it the way a successful run ends
    (clients disconnected, gRPC server stopped). Raised out of start_server()
    instead, it left both running and the process stuck; main() reports it."""

    error: Optional[Exception] = None

    def fit(self, num_rounds: int, timeout: Optional[float]):
        try:
            return super().fit(num_rounds, timeout)
        except Exception as exc:
            self.error = exc
            return fl.server.History(), 0.0


class ExecutionQuorumNotMet(RuntimeError):
    """Fewer valid updates than min_fit_clients in a round: nothing is aggregated."""


class EvidenceFedAvg(FedAvg):
    def __init__(
        self,
        *,
        model: Net,
        expected_rounds: int,
        guest_admitted: bool = False,
        **kwargs: Any,
    ) -> None:
        super().__init__(**kwargs)
        self.model = model
        self.expected_rounds = expected_rounds
        # True only for a Mode 1A run whose guest contribution the Gatekeeper allowed.
        self.guest_admitted = guest_admitted
        # Honest completion: only rounds that produced an aggregate count.
        self.rounds_aggregated = 0
        self.participants: Dict[str, Dict[str, Any]] = {}
        self.fit_metrics: Dict[int, Metrics] = {}
        self.fit_counts: Dict[int, Tuple[int, int]] = {}
        # round -> {client cid: proven org_id} (issue #7)
        self.admitted: Dict[int, Dict[str, str]] = {}

    def write_participants(self) -> None:
        participants_path().write_text(
            json.dumps(
                {
                    "run_id": current_artifact_run_id() or RUN_ID,
                    "participants": [
                        self.participants[participant_id]
                        for participant_id in sorted(self.participants)
                    ],
                },
                indent=2,
            ),
            encoding="utf-8",
        )

    def configure_fit(
        self,
        server_round: int,
        parameters: Parameters,
        client_manager: Any,
    ):
        update_training_state(status="running", round=server_round)
        write_event("round_fit_configured", round=server_round)

        # Issue #7: only clients that prove an admitted organisation's Flower
        # execution key take part, one connection per organisation. Too few
        # within the timeout: the round fails closed (no aggregation).
        with bound_envelope_lock:
            binding = dict(bound_envelope or {})
        envelope_id = str(binding.get("envelope_id") or "")
        keys = admission_keys(binding, self.guest_admitted)
        run_id = current_artifact_run_id() or RUN_ID
        # The timeout starts once Flower has sampled clients (configure_fit waits for
        # enough connections), so slow-starting honest clients are not failed early.
        deadline: Optional[float] = None
        while True:
            # Every round, and every retry, re-checks the envelope's validity window.
            if envelope_expired(binding.get("valid_until"), time.time()):
                write_event(
                    "round_envelope_expired",
                    round=server_round,
                    envelope_id=envelope_id,
                    valid_until=binding.get("valid_until"),
                )
                raise EnvelopeExpired(
                    f"round {server_round}: envelope {envelope_id} expired or has no valid_until"
                )
            instructions = super().configure_fit(
                server_round, parameters, client_manager
            )
            if not instructions:
                # Fewer clients connected than the round needs within
                # CLIENT_WAIT_TIMEOUT_SECONDS: a required hospital is missing.
                connected = client_manager.num_available()
                write_event(
                    "round_clients_missing",
                    round=server_round,
                    connected=connected,
                    required=self.min_available_clients,
                )
                raise AdmissionThresholdNotMet(
                    f"round {server_round}: {connected} client(s) connected "
                    f"within {CLIENT_WAIT_TIMEOUT_SECONDS:g} s, "
                    f"{self.min_available_clients} required"
                )
            admitted, orgs, rejected = admit(
                instructions,
                keys,
                envelope_id,
                run_id,
                server_round,
            )
            if deadline is None:
                deadline = time.monotonic() + ADMISSION_TIMEOUT_SECONDS
            for cid, reason in rejected:
                write_event(
                    "flower_client_rejected",
                    round=server_round,
                    client=cid,
                    reason=reason,
                )
            if len(admitted) >= self.min_fit_clients:
                break
            if time.monotonic() >= deadline:
                write_event(
                    "round_admission_failed",
                    round=server_round,
                    admitted=sorted(orgs.values()),
                    required=self.min_fit_clients,
                )
                raise AdmissionThresholdNotMet(
                    f"round {server_round}: {len(admitted)} admitted client(s) "
                    f"proved their identity, {self.min_fit_clients} required"
                )
            time.sleep(ADMISSION_RETRY_SECONDS)

        self.admitted[server_round] = orgs
        write_event(
            "round_clients_admitted",
            round=server_round,
            participants=sorted(orgs.values()),
        )
        return admitted

    def aggregate_fit(
        self,
        server_round: int,
        results: List[Tuple[ClientProxy, Any]],
        failures: List[Any],
    ):
        # Issue #7: only results from this round's admitted connections count,
        # recorded under the proven organisation, not the self-reported one.
        admitted = self.admitted.get(server_round, {})
        results = [
            (client, fit_result)
            for client, fit_result in results
            if client.cid in admitted
        ]
        # Issue #7: the quorum holds before aggregation. A round that lost an admitted
        # client during training must not change the model; the run fails closed.
        if len(results) < int(self.min_fit_clients):
            write_event(
                "round_quorum_not_met",
                round=server_round,
                valid_updates=len(results),
                failure_count=len(failures),
                required=int(self.min_fit_clients),
            )
            raise ExecutionQuorumNotMet(
                f"round {server_round}: {len(results)} valid update(s), "
                f"{int(self.min_fit_clients)} required; nothing aggregated"
            )
        parameters, metrics = super().aggregate_fit(
            server_round,
            results,
            failures,
        )
        if parameters is not None:
            self.rounds_aggregated += 1

        for client, _fit_result in results:
            participant = admitted[client.cid]
            self.participants[participant] = {
                "participant_id": participant,
                "last_seen_round": server_round,
                "last_event": "fit_completed",
            }

        self.write_participants()
        self.fit_metrics[server_round] = metrics or {}
        self.fit_counts[server_round] = (
            len(results),
            len(failures),
        )

        if parameters is not None:
            set_parameters(
                self.model,
                parameters_to_ndarrays(parameters),
            )
            torch.save(
                {
                    key: value.detach().cpu()
                    for key, value in self.model.state_dict().items()
                },
                checkpoint_path(),
            )

        write_event(
            "round_fit_aggregated",
            round=server_round,
            client_count=len(results),
            failure_count=len(failures),
            metrics=metrics,
        )
        return parameters, metrics


def write_final_metadata(
    *,
    config: Dict[str, Any],
    rounds_completed: int,
    status: str,
    error: Optional[str] = None,
) -> None:
    artifact = checkpoint_path()
    metadata = {
        "run_id": current_artifact_run_id() or RUN_ID,
        "session_id": current_session_id(),
        "phase": config.get("phase", "AB_BASE"),
        "timestamp": utc_now(),
        "status": status,
        "dataset": config.get("dataset", "medmnist"),
        "dataset_subset": config.get(
            "dataset_subset",
            "pathmnist",
        ),
        "aggregation_strategy": "FedAvg",
        "rounds_completed": rounds_completed,
        "model_artifact": str(artifact) if artifact.exists() else None,
        "model_sha256": (
            file_sha256(artifact) if artifact.exists() else None
        ),
        "ignored_labels": sorted(IGNORED_CLASSES),
        "active_labels": ACTIVE_CLASSES,
        "data_partition_profile": config.get(
            "data_partition_profile",
            PATHMNIST_PARTITION_PROFILE,
        ),
        "data_partition_seed": config.get(
            "data_partition_seed",
            PATHMNIST_PARTITION_SEED,
        ),
        "error": error,
    }
    final_model_metadata_path().write_text(
        json.dumps(metadata, indent=2),
        encoding="utf-8",
    )


def write_envelope_run_summary(
    *,
    phase: str,
    status: str,
    rounds_completed: int,
    error: Optional[str] = None,
) -> None:
    session_id = current_session_id()
    if not session_id:
        return
    if status == "completed" and not checkpoint_path().is_file():
        raise RuntimeError(
            "Completed training did not produce a model artefact"
        )

    target = VAULT_ROOT / session_id
    target.mkdir(parents=True, exist_ok=True)
    payload = {
        "run_id": current_artifact_run_id() or RUN_ID,
        "session_id": session_id,
        "phase": phase,
        "status": status,
        "rounds_completed": rounds_completed,
        "artifacts": {
            "experiment_config": str(run_dir() / "experiment_config.json"),
            "events": str(events_path()),
            "participants": str(participants_path()),
            "metrics": str(metrics_path()),
            "model": str(checkpoint_path()),
            "class_metrics": str(class_metrics_path()),
            "confusion_counts": str(confusion_counts_path()),
            "confusion_normalized": str(
                confusion_normalized_path()
            ),
        },
        "error": error,
    }
    pointer_path = target / "run.json"
    temporary_path = target / "run.json.tmp"
    temporary_path.write_text(
        json.dumps(payload, indent=2),
        encoding="utf-8",
    )
    temporary_path.replace(pointer_path)


def main() -> None:
    seed_everything()
    control_run_dir()
    update_training_state(status="waiting")

    write_event(
        "server_starting",
        server_address=SERVER_ADDRESS,
        hub_url=HUB_URL,
        strategy="FedAvg",
        central_evaluation=True,
    )

    start_control_plane()
    wait_for_control_plane()
    register_with_hub()

    activation = wait_for_experiment_start()
    if activation.get("status") in {"completed", "failed"}:
        keep_control_plane_alive()
        return

    # Issue #7: any failure after START, setup included, is reported to the hub as
    # failed and the server goes idle, so nothing restarts a run by itself.
    run: Dict[str, Any] = {}
    try:
        run_training(run)
    except Exception as exc:
        report_failed_run(exc, run)
    keep_control_plane_alive()


def run_training(run: Dict[str, Any]) -> None:
    """One run after START. Fills ``run`` for report_failed_run()."""
    if current_session_id() is None:
        raise RuntimeError("Experiment activated without a bound envelope")

    allocated_run_id = allocate_training_run()
    run["run_id"] = allocated_run_id
    config = {
        **load_experiment_config(),
        "data_partition_profile": PATHMNIST_PARTITION_PROFILE,
        "data_partition_seed": PATHMNIST_PARTITION_SEED,
    }
    phase = str(config.get("phase") or "AB_BASE").strip().upper()
    run.update(config=config, phase=phase)
    if phase not in {"AB_BASE", "MODE1A"}:
        raise RuntimeError(f"Unsupported training phase: {phase!r}")

    training_min_clients = (
        MODE1A_TRAINING_MIN_CLIENTS
        if phase == "MODE1A"
        else positive_int(config, "min_clients", DEFAULT_MIN_CLIENTS)
    )
    config["phase"] = phase
    config["training_min_clients"] = training_min_clients

    update_training_state(
        status="admission_pending" if phase == "MODE1A" else "running",
        phase=phase,
        min_clients=training_min_clients,
        round=0,
    )
    require_mode1a_guest_admission(allocated_run_id, phase)

    (run_dir() / "experiment_config.json").write_text(
        json.dumps({**config, "run_id": allocated_run_id}, indent=2),
        encoding="utf-8",
    )
    ensure_metrics_header()
    rounds = positive_int(config, "rounds", DEFAULT_ROUNDS)
    min_clients = positive_int(
        config,
        "training_min_clients",
        training_min_clients,
    )
    fraction_fit = bounded_fraction(
        config,
        "fraction_fit",
        DEFAULT_FRACTION_FIT,
    )

    update_training_state(
        status="running",
        phase=phase,
        min_clients=min_clients,
        round=0,
        rounds=rounds,
    )

    model = Net().to(DEVICE)
    test_loader = make_test_loader()
    strategy: EvidenceFedAvg

    def central_evaluate(server_round, parameters, eval_config):
        set_parameters(model, parameters)
        (
            loss,
            accuracy,
            macro_recall,
            per_class_recall,
            confusion,
            per_class_metrics,
        ) = evaluate_full_test(model, test_loader)

        story = story_metrics(per_class_metrics)
        fit = strategy.fit_metrics.get(server_round, {})
        client_count, failure_count = strategy.fit_counts.get(
            server_round,
            (0, 0),
        )

        with metrics_path().open(
            "a",
            newline="",
            encoding="utf-8",
        ) as handle:
            csv.writer(handle).writerow(
                [
                    current_artifact_run_id() or RUN_ID,
                    current_session_id(),
                    phase,
                    server_round,
                    client_count,
                    failure_count,
                    fit.get("train_loss", ""),
                    fit.get("train_accuracy", ""),
                    loss,
                    accuracy,
                    macro_recall,
                    story["non_cancer_recall"],
                    story["cancer_recall"],
                    story["cancer_f1"],
                    *cancer_class_recalls(per_class_recall).values(),
                ]
            )

        save_confusion_matrix(
            confusion_counts_path(),
            confusion,
            normalized=False,
        )
        save_confusion_matrix(
            confusion_normalized_path(),
            confusion,
            normalized=True,
        )
        save_class_metrics(
            class_metrics_path(),
            per_class_metrics,
        )

        update_training_state(
            status="running",
            round=server_round,
            overall_accuracy=accuracy,
            macro_recall=macro_recall,
            non_cancer_recall=story["non_cancer_recall"],
            cancer_recall=story["cancer_recall"],
            cancer_f1=story["cancer_f1"],
            **cancer_class_recalls(per_class_recall),
        )
        write_event(
            "round_central_evaluation_completed",
            round=server_round,
            loss=loss,
            accuracy=accuracy,
            macro_recall=macro_recall,
            **story,
            **cancer_class_recalls(per_class_recall),
        )

        print(
            f"round={server_round:3d} "
            f"overall={accuracy:.4f} "
            f"macro={macro_recall:.4f} "
            f"non_cancer={story['non_cancer_recall']:.4f} "
            f"cancer={story['cancer_recall']:.4f} "
            f"cancer_f1={story['cancer_f1']:.4f}",
            flush=True,
        )

        return loss, {
            "accuracy": accuracy,
            "macro_recall": macro_recall,
            "non_cancer_recall": story["non_cancer_recall"],
            "cancer_recall": story["cancer_recall"],
            "cancer_f1": story["cancer_f1"],
            **cancer_class_recalls(per_class_recall),
        }

    strategy = EvidenceFedAvg(
        model=model,
        expected_rounds=rounds,
        fraction_fit=fraction_fit,
        fraction_evaluate=0.0,
        min_fit_clients=min_clients,
        min_available_clients=min_clients,
        # require_mode1a_guest_admission() returned only after an ALLOW.
        guest_admitted=phase == "MODE1A",
        fit_metrics_aggregation_fn=fit_metrics_aggregation_fn,
        evaluate_fn=central_evaluate,
        initial_parameters=ndarrays_to_parameters(
            get_parameters(model)
        ),
    )

    run["strategy"] = strategy
    flower = CleanStopServer(
        client_manager=BoundedClientManager(),
        strategy=strategy,
    )
    fl.server.start_server(
        server_address=SERVER_ADDRESS,
        server=flower,
        config=fl.server.ServerConfig(
            num_rounds=rounds,
            round_timeout=ROUND_TIMEOUT_SECONDS,
        ),
    )
    if flower.error is not None:
        raise flower.error

    rounds_completed = strategy.rounds_aggregated
    run_ok = rounds_completed == rounds
    final_status = "completed" if run_ok else "failed"
    problem = None if run_ok else f"rounds_aggregated={rounds_completed}/{rounds}"
    update_training_state(
        status="done" if run_ok else "error",
        round=rounds_completed,
        error=problem,
    )
    write_final_metadata(
        config=config,
        rounds_completed=rounds_completed,
        status=final_status,
        error=problem,
    )
    write_envelope_run_summary(
        phase=phase,
        status=final_status,
        rounds_completed=rounds_completed,
        error=problem,
    )
    write_event(
        "server_completed",
        flower_rounds=rounds_completed,
        status=final_status,
    )
    notify_hub_finished(problem)


def report_failed_run(exc: Exception, run: Dict[str, Any]) -> None:
    """Issue #7: record the failure, tell the hub and go idle, as after a success.
    Raising instead left the hub 'running', so a restarted server began a run itself."""
    # An exception without a message (a bare assert, MemoryError()) is still a
    # failure; an empty reason would be reported to the hub as completed.
    reason = str(exc) or type(exc).__name__
    strategy = run.get("strategy")
    rounds_completed = strategy.rounds_aggregated if strategy is not None else 0
    update_training_state(
        status="error",
        round=rounds_completed,
        error=reason,
    )
    # Only a run allocated after this START has evidence to write; before that, the
    # paths still point at the previous run. Never let a write hide the failure.
    if run.get("run_id"):
        try:
            write_final_metadata(
                config=run.get("config", {}),
                rounds_completed=rounds_completed,
                status="failed",
                error=reason,
            )
        except Exception as metadata_exc:
            write_event("final_metadata_failed", error=str(metadata_exc))
        # The envelope's run.json must not keep describing the previous run.
        try:
            write_envelope_run_summary(
                phase=run.get("phase", "AB_BASE"),
                status="failed",
                rounds_completed=rounds_completed,
                error=reason,
            )
        except Exception as summary_exc:
            write_event("run_summary_failed", error=str(summary_exc))
    write_event("server_failed", error=reason)
    notify_hub_finished(reason)


if __name__ == "__main__":
    main()
