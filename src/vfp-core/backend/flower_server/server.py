#!/usr/bin/env python3
"""OpenHealth Flower coordinator for the validated A+B PathMNIST workload.

The existing governance boundary is preserved:
- Hub controls experiment activation.
- The backend accepts a Hub-approved envelope binding.
- Flower training starts only after the Hub marks the run as ``running``.

This first integration slice implements AB_BASE only. Hospital C and the
Guest/Member/Founder workflows are deliberately absent.
"""

from __future__ import annotations

import csv
import hashlib
import json
import os
import socket
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
from fastapi import FastAPI
from flwr.common import (
    Metrics,
    Parameters,
    ndarrays_to_parameters,
    parameters_to_ndarrays,
)
from flwr.server.client_proxy import ClientProxy
from flwr.server.strategy import FedAvg
from pydantic import BaseModel, Field

from pathmnist.common import (
    ACTIVE_CLASSES,
    CLASS_NAMES,
    DEVICE,
    IGNORED_CLASSES,
    Net,
    STORY_CANCER_CLASSES,
    STORY_NON_CANCER_CLASSES,
    evaluate_full_test,
    get_parameters,
    make_test_loader,
    seed_everything,
    set_parameters,
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

PHASE = "AB_BASE"

# ---------------------------------------------------------------------
# Runtime state and control plane
# ---------------------------------------------------------------------

control_app = FastAPI(title="OpenHealth Flower backend control plane")
bound_envelope: Optional[Dict[str, Any]] = None
bound_envelope_lock = threading.Lock()

training_state: Dict[str, Any] = {
    "status": "waiting",
    "phase": PHASE,
    "round": 0,
    "rounds": DEFAULT_ROUNDS,
    "overall_accuracy": None,
    "macro_recall": None,
    "non_cancer_recall": None,
    "cancer_recall": None,
    "cancer_f1": None,
    "class_7_recall": None,
    "class_8_recall": None,
    "error": None,
}
training_state_lock = threading.Lock()


class EnvelopeBinding(BaseModel):
    envelope_id: str
    allowed_ops: List[str] = Field(default_factory=list)
    policy_hash: Optional[str] = None
    valid_until: Optional[int] = None
    participants: List[str] = Field(default_factory=list)
    scope: Dict[str, Any] = Field(default_factory=dict)


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
        "bound_envelope": envelope,
        "training": training,
    }


@control_app.post("/bind_envelope")
def bind_envelope(binding: EnvelopeBinding) -> Dict[str, Any]:
    """Record a Hub-approved binding without starting Flower training."""

    global bound_envelope

    payload = model_dict(binding)
    payload["bound_at"] = utc_now()

    with bound_envelope_lock:
        bound_envelope = payload

    (run_dir() / "bound_envelope.json").write_text(
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
    }


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

def run_dir() -> Path:
    path = RUNS_DIR / RUN_ID
    path.mkdir(parents=True, exist_ok=True)
    return path


def events_path() -> Path:
    return run_dir() / "events.jsonl"


def metrics_path() -> Path:
    return run_dir() / "metrics.csv"


def participants_path() -> Path:
    return run_dir() / "participants.json"


def experiment_config_path() -> Path:
    return run_dir() / "experiment_config.json"


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
        "run_id": RUN_ID,
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
            "phase": PHASE,
            "central_evaluation": True,
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


def notify_hub_completed() -> None:
    while True:
        try:
            response = requests.post(
                f"{HUB_URL}/experiments/{RUN_ID}/complete",
                timeout=5,
            )
            response.raise_for_status()
            write_event(
                "hub_completion_notified",
                response=response.json(),
            )
            return
        except Exception as exc:
            write_event(
                "hub_completion_notify_failed",
                error=str(exc),
                retry_seconds=COMPLETION_RETRY_SECONDS,
            )
            time.sleep(COMPLETION_RETRY_SECONDS)


def keep_control_plane_alive() -> None:
    write_event("server_control_plane_idle")
    threading.Event().wait()


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
                "class_7_recall",
                "class_8_recall",
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

def participant_identity(metrics: Metrics) -> Optional[str]:
    org_id = metrics.get("org_id")
    if org_id:
        return str(org_id)
    hospital = metrics.get("hospital")
    if hospital:
        return f"org://Hospital{str(hospital).upper()}"
    return None


class EvidenceFedAvg(FedAvg):
    def __init__(
        self,
        *,
        model: Net,
        expected_rounds: int,
        **kwargs: Any,
    ) -> None:
        super().__init__(**kwargs)
        self.model = model
        self.expected_rounds = expected_rounds
        self.participants: Dict[str, Dict[str, Any]] = {}
        self.fit_metrics: Dict[int, Metrics] = {}
        self.fit_counts: Dict[int, Tuple[int, int]] = {}

    def write_participants(self) -> None:
        participants_path().write_text(
            json.dumps(
                {
                    "run_id": RUN_ID,
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
        return super().configure_fit(
            server_round,
            parameters,
            client_manager,
        )

    def aggregate_fit(
        self,
        server_round: int,
        results: List[Tuple[ClientProxy, Any]],
        failures: List[Any],
    ):
        parameters, metrics = super().aggregate_fit(
            server_round,
            results,
            failures,
        )

        for _client, fit_result in results:
            participant = participant_identity(
                fit_result.metrics or {}
            )
            if participant:
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
        "run_id": RUN_ID,
        "session_id": current_session_id(),
        "phase": PHASE,
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
        "error": error,
    }
    final_model_metadata_path().write_text(
        json.dumps(metadata, indent=2),
        encoding="utf-8",
    )


def write_envelope_run_summary(
    *,
    status: str,
    rounds_completed: int,
    error: Optional[str] = None,
) -> None:
    session_id = current_session_id()
    if not session_id:
        return

    target = VAULT_ROOT / session_id
    target.mkdir(parents=True, exist_ok=True)
    payload = {
        "run_id": RUN_ID,
        "session_id": session_id,
        "phase": PHASE,
        "status": status,
        "rounds_completed": rounds_completed,
        "artifacts": {
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
    (target / "run.json").write_text(
        json.dumps(payload, indent=2),
        encoding="utf-8",
    )


def main() -> None:
    seed_everything()
    run_dir()
    ensure_metrics_header()
    update_training_state(status="waiting")

    write_event(
        "server_starting",
        server_address=SERVER_ADDRESS,
        hub_url=HUB_URL,
        phase=PHASE,
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

    if current_session_id() is None:
        error = "Experiment activated without a bound envelope"
        update_training_state(status="error", error=error)
        write_event("server_failed", error=error)
        raise RuntimeError(error)

    config = load_experiment_config()
    rounds = positive_int(config, "rounds", DEFAULT_ROUNDS)
    min_clients = positive_int(
        config,
        "min_clients",
        DEFAULT_MIN_CLIENTS,
    )
    fraction_fit = bounded_fraction(
        config,
        "fraction_fit",
        DEFAULT_FRACTION_FIT,
    )

    update_training_state(
        status="running",
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
                    RUN_ID,
                    current_session_id(),
                    PHASE,
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
                    per_class_recall[7],
                    per_class_recall[8],
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
            class_7_recall=per_class_recall[7],
            class_8_recall=per_class_recall[8],
        )
        write_event(
            "round_central_evaluation_completed",
            round=server_round,
            loss=loss,
            accuracy=accuracy,
            macro_recall=macro_recall,
            **story,
            class_7_recall=per_class_recall[7],
            class_8_recall=per_class_recall[8],
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
            "class_7_recall": per_class_recall[7],
            "class_8_recall": per_class_recall[8],
        }

    strategy = EvidenceFedAvg(
        model=model,
        expected_rounds=rounds,
        fraction_fit=fraction_fit,
        fraction_evaluate=0.0,
        min_fit_clients=min_clients,
        min_available_clients=min_clients,
        fit_metrics_aggregation_fn=fit_metrics_aggregation_fn,
        evaluate_fn=central_evaluate,
        initial_parameters=ndarrays_to_parameters(
            get_parameters(model)
        ),
    )

    try:
        fl.server.start_server(
            server_address=SERVER_ADDRESS,
            config=fl.server.ServerConfig(num_rounds=rounds),
            strategy=strategy,
        )

        update_training_state(
            status="done",
            round=rounds,
        )
        write_final_metadata(
            config=config,
            rounds_completed=rounds,
            status="completed",
        )
        write_envelope_run_summary(
            status="completed",
            rounds_completed=rounds,
        )
        write_event("server_completed", flower_rounds=rounds)
        notify_hub_completed()
        keep_control_plane_alive()
    except Exception as exc:
        update_training_state(
            status="error",
            error=str(exc),
        )
        write_final_metadata(
            config=config,
            rounds_completed=0,
            status="failed",
            error=str(exc),
        )
        write_envelope_run_summary(
            status="failed",
            rounds_completed=0,
            error=str(exc),
        )
        write_event("server_failed", error=str(exc))
        raise


if __name__ == "__main__":
    main()
