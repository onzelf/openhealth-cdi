# src/vfp-core/backend/flower_server/server.py
#
# Flower coordinator for OpenHealth PathMNIST experiments.
#
# The federation envelope establishes who may participate. It does not start
# training. Training begins only after the Hub marks the selected experiment
# as "running" (for example, after the user presses START in the frontend).
#
# This service contains no admission logic and no backend-registration logic.
# It coordinates Flower rounds and records experiment evidence.

from __future__ import annotations

import csv
import json
import os
import socket
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import flwr as fl
import requests
import uvicorn
from fastapi import FastAPI
from flwr.common import Metrics, Parameters
from flwr.server.client_proxy import ClientProxy
from flwr.server.strategy import FedAvg
from pydantic import BaseModel, Field


# ---------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------

HUB_URL = os.getenv("HUB_URL", "http://fc-hub:8080").rstrip("/")
RUN_ID = os.getenv("RUN_ID", "pathmnist-ab-001")
RUNS_DIR = Path(os.getenv("RUNS_DIR", "/vault/runs"))

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
    os.getenv("FLOWER_ROUNDS", os.getenv("NUM_ROUNDS", "3"))
)
DEFAULT_MIN_CLIENTS = int(
    os.getenv(
        "MIN_CLIENTS",
        os.getenv("MIN_AVAILABLE_CLIENTS", "2"),
    )
)
DEFAULT_FRACTION_FIT = float(os.getenv("FRACTION_FIT", "1.0"))
DEFAULT_FRACTION_EVALUATE = float(
    os.getenv("FRACTION_EVALUATE", "1.0")
)


# ---------------------------------------------------------------------
# Hub-facing backend control plane
# ---------------------------------------------------------------------

control_app = FastAPI(title="OpenHealth Flower backend control plane")
bound_envelope: Optional[Dict[str, Any]] = None
bound_envelope_lock = threading.Lock()


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


@control_app.post("/bind_envelope")
def bind_envelope(binding: EnvelopeBinding) -> Dict[str, Any]:
    """Record a Hub-approved binding without starting Flower training."""
    global bound_envelope

    payload = model_dict(binding)
    payload["bound_at"] = utc_now()

    with bound_envelope_lock:
        bound_envelope = payload

    binding_path = run_dir() / "bound_envelope.json"
    binding_path.write_text(
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


# ---------------------------------------------------------------------
# Evidence paths
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


def final_model_metadata_path() -> Path:
    return run_dir() / "final_model_metadata.json"


# ---------------------------------------------------------------------
# Logging and JSON helpers
# ---------------------------------------------------------------------

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

    with events_path().open("a", encoding="utf-8") as file:
        file.write(json.dumps(json_safe(event)) + "\n")


def ensure_metrics_header() -> None:
    path = metrics_path()
    if path.exists():
        return

    with path.open("w", newline="", encoding="utf-8") as file:
        writer = csv.writer(file)
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


def append_metrics_row(
    *,
    server_round: int,
    phase: str,
    client_count: int,
    failure_count: int,
    loss: Optional[float] = None,
    accuracy: Optional[float] = None,
    train_loss: Optional[float] = None,
    train_accuracy: Optional[float] = None,
) -> None:
    ensure_metrics_header()

    with metrics_path().open("a", newline="", encoding="utf-8") as file:
        writer = csv.writer(file)
        writer.writerow(
            [
                RUN_ID,
                server_round,
                phase,
                client_count,
                failure_count,
                "" if loss is None else loss,
                "" if accuracy is None else accuracy,
                "" if train_loss is None else train_loss,
                "" if train_accuracy is None else train_accuracy,
            ]
        )


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
            raise ValueError(
                "Hub response does not contain experiment_config"
            )

        experiment_config_path().write_text(
            json.dumps(config, indent=2),
            encoding="utf-8",
        )
        write_event("experiment_config_fetched_from_hub")
        return config

    except Exception as exc:
        write_event(
            "experiment_config_fetch_failed",
            error=str(exc),
        )
        return None


def load_experiment_config() -> Dict[str, Any]:
    path = experiment_config_path()

    if path.exists():
        try:
            config = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(config, dict):
                write_event(
                    "experiment_config_loaded",
                    source="shared_run_directory",
                )
                return config
        except Exception as exc:
            write_event(
                "experiment_config_read_failed",
                error=str(exc),
            )

    fetched = fetch_experiment_config_from_hub()
    if fetched is not None:
        return fetched

    fallback = {
        "run_id": RUN_ID,
        "dataset": "medmnist",
        "dataset_subset": "pathmnist",
        "aggregation_strategy": "FedAvg",
        "rounds": DEFAULT_ROUNDS,
        "min_clients": DEFAULT_MIN_CLIENTS,
        "fraction_fit": DEFAULT_FRACTION_FIT,
        "fraction_evaluate": DEFAULT_FRACTION_EVALUATE,
    }

    write_event(
        "experiment_config_fallback_used",
        config=fallback,
    )
    return fallback


def positive_int(
    config: Dict[str, Any],
    key: str,
    default: int,
) -> int:
    try:
        return max(1, int(config.get(key, default)))
    except (TypeError, ValueError):
        write_event(
            "invalid_experiment_config_value",
            key=key,
            value=config.get(key),
            fallback=default,
        )
        return default


def bounded_fraction(
    config: Dict[str, Any],
    key: str,
    default: float,
) -> float:
    try:
        value = float(config.get(key, default))
    except (TypeError, ValueError):
        write_event(
            "invalid_experiment_config_value",
            key=key,
            value=config.get(key),
            fallback=default,
        )
        return default

    if not 0.0 < value <= 1.0:
        write_event(
            "invalid_experiment_config_value",
            key=key,
            value=value,
            fallback=default,
        )
        return default

    return value


# ---------------------------------------------------------------------
# Hub-controlled experiment lifecycle
# ---------------------------------------------------------------------

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

            if current_status in {
                "completed",
                "failed",
            }:
                write_event(
                    "server_terminal_status_received",
                    experiment_status=status,
                )
                return status

        except RuntimeError:
            raise

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
# Metric aggregation
# ---------------------------------------------------------------------

def weighted_average(
    metrics: List[Tuple[int, Metrics]],
    key: str,
) -> Optional[float]:
    total_examples = 0
    weighted_sum = 0.0

    for num_examples, metric in metrics:
        value = metric.get(key)
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

    train_loss = weighted_average(metrics, "train_loss")
    train_accuracy = weighted_average(
        metrics,
        "train_accuracy",
    )

    if train_loss is not None:
        result["train_loss"] = train_loss

    if train_accuracy is not None:
        result["train_accuracy"] = train_accuracy

    return result


def evaluate_metrics_aggregation_fn(
    metrics: List[Tuple[int, Metrics]],
) -> Metrics:
    result: Metrics = {}

    accuracy = weighted_average(metrics, "accuracy")

    if accuracy is not None:
        result["accuracy"] = accuracy

    return result


# ---------------------------------------------------------------------
# Evidence-aware FedAvg
# ---------------------------------------------------------------------

def participant_identity(metrics: Metrics) -> Optional[str]:
    org_id = metrics.get("org_id")
    if org_id:
        return str(org_id)

    hospital = metrics.get("hospital")
    if hospital:
        hospital_name = str(hospital).upper()
        if hospital_name in {"A", "B", "C"}:
            return f"org://Hospital{hospital_name}"
        return f"hospital:{hospital_name}"

    return None


class EvidenceFedAvg(FedAvg):
    def __init__(
        self,
        *,
        expected_rounds: int,
        **kwargs: Any,
    ) -> None:
        super().__init__(**kwargs)
        self.expected_rounds = expected_rounds
        self.participants: Dict[str, Dict[str, Any]] = {}

    def write_participants(self) -> None:
        payload = {
            "run_id": RUN_ID,
            "participants": [
                self.participants[participant_id]
                for participant_id in sorted(self.participants)
            ],
        }

        participants_path().write_text(
            json.dumps(payload, indent=2),
            encoding="utf-8",
        )

    def configure_fit(
        self,
        server_round: int,
        parameters: Parameters,
        client_manager: Any,
    ):
        write_event(
            "round_fit_configured",
            round=server_round,
        )
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
        parameters_aggregated, metrics_aggregated = (
            super().aggregate_fit(
                server_round,
                results,
                failures,
            )
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

        write_event(
            "round_fit_aggregated",
            round=server_round,
            client_count=len(results),
            failure_count=len(failures),
            metrics=metrics_aggregated,
        )

        append_metrics_row(
            server_round=server_round,
            phase="fit",
            client_count=len(results),
            failure_count=len(failures),
            train_loss=metrics_aggregated.get("train_loss"),
            train_accuracy=metrics_aggregated.get(
                "train_accuracy"
            ),
        )

        return parameters_aggregated, metrics_aggregated

    def configure_evaluate(
        self,
        server_round: int,
        parameters: Parameters,
        client_manager: Any,
    ):
        write_event(
            "round_evaluate_configured",
            round=server_round,
        )
        return super().configure_evaluate(
            server_round,
            parameters,
            client_manager,
        )

    def aggregate_evaluate(
        self,
        server_round: int,
        results: List[Tuple[ClientProxy, Any]],
        failures: List[Any],
    ):
        loss_aggregated, metrics_aggregated = (
            super().aggregate_evaluate(
                server_round,
                results,
                failures,
            )
        )

        for _client, evaluate_result in results:
            participant = participant_identity(
                evaluate_result.metrics or {}
            )
            if participant:
                self.participants[participant] = {
                    "participant_id": participant,
                    "last_seen_round": server_round,
                    "last_event": "evaluation_completed",
                }

        self.write_participants()

        write_event(
            "round_evaluate_aggregated",
            round=server_round,
            client_count=len(results),
            failure_count=len(failures),
            loss=loss_aggregated,
            metrics=metrics_aggregated,
        )

        append_metrics_row(
            server_round=server_round,
            phase="evaluate",
            client_count=len(results),
            failure_count=len(failures),
            loss=loss_aggregated,
            accuracy=metrics_aggregated.get("accuracy"),
        )

        return loss_aggregated, metrics_aggregated


# ---------------------------------------------------------------------
# Final metadata
# ---------------------------------------------------------------------

def write_final_model_metadata(
    *,
    config: Dict[str, Any],
    rounds_completed: int,
    status: str,
    error: Optional[str] = None,
) -> None:
    metadata = {
        "run_id": RUN_ID,
        "timestamp": utc_now(),
        "status": status,
        "dataset": config.get("dataset", "medmnist"),
        "dataset_subset": config.get(
            "dataset_subset",
            "pathmnist",
        ),
        "aggregation_strategy": config.get(
            "aggregation_strategy",
            "FedAvg",
        ),
        "rounds_completed": rounds_completed,
        "model_artifact": None,
        "note": (
            "The Flower coordinator records experiment metadata "
            "and metrics. Model serving is a separate component."
        ),
        "error": error,
    }

    final_model_metadata_path().write_text(
        json.dumps(metadata, indent=2),
        encoding="utf-8",
    )


# ---------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------

def main() -> None:
    run_dir()
    ensure_metrics_header()

    write_event(
        "server_starting",
        server_address=SERVER_ADDRESS,
        hub_url=HUB_URL,
        default_rounds=DEFAULT_ROUNDS,
        default_min_clients=DEFAULT_MIN_CLIENTS,
        strategy="FedAvg",
    )

    start_control_plane()
    wait_for_control_plane()
    register_with_hub()

    activation = wait_for_experiment_start()
    if activation.get("status") in {"completed", "failed"}:
        keep_control_plane_alive()
        return

    config = load_experiment_config()

    rounds = positive_int(
        config,
        "rounds",
        DEFAULT_ROUNDS,
    )
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
    fraction_evaluate = bounded_fraction(
        config,
        "fraction_evaluate",
        DEFAULT_FRACTION_EVALUATE,
    )

    write_event(
        "server_starting_flower",
        server_address=SERVER_ADDRESS,
        dataset=config.get("dataset", "medmnist"),
        dataset_subset=config.get(
            "dataset_subset",
            "pathmnist",
        ),
        flower_rounds=rounds,
        min_clients=min_clients,
        fraction_fit=fraction_fit,
        fraction_evaluate=fraction_evaluate,
        strategy="FedAvg",
    )

    strategy = EvidenceFedAvg(
        expected_rounds=rounds,
        fraction_fit=fraction_fit,
        fraction_evaluate=fraction_evaluate,
        min_fit_clients=min_clients,
        min_evaluate_clients=min_clients,
        min_available_clients=min_clients,
        fit_metrics_aggregation_fn=(
            fit_metrics_aggregation_fn
        ),
        evaluate_metrics_aggregation_fn=(
            evaluate_metrics_aggregation_fn
        ),
    )

    try:
        fl.server.start_server(
            server_address=SERVER_ADDRESS,
            config=fl.server.ServerConfig(
                num_rounds=rounds
            ),
            strategy=strategy,
        )

        write_final_model_metadata(
            config=config,
            rounds_completed=rounds,
            status="completed",
        )
        write_event(
            "server_completed",
            flower_rounds=rounds,
        )
        notify_hub_completed()
        keep_control_plane_alive()

    except Exception as exc:
        write_final_model_metadata(
            config=config,
            rounds_completed=0,
            status="failed",
            error=str(exc),
        )
        write_event(
            "server_failed",
            error=str(exc),
        )
        raise


if __name__ == "__main__":
    main()
