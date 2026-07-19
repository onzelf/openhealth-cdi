#!/usr/bin/env python3
"""OpenHealth Flower client for the validated A+B PathMNIST workload.

This process preserves the existing Hub registration and Flower connection
lifecycle. Dataset partitioning, the model, and local training are imported
from the frozen standalone implementation.
"""

from __future__ import annotations

import os
import time
from typing import Any, Dict

import flwr as fl
import requests
import torch

from pathmnist.common import (
    ACTIVE_CLASSES,
    CANCER_SAMPLES_PER_AB_HOSPITAL,
    DEVICE,
    IGNORED_CLASSES,
    LOCAL_EPOCHS,
    Net,
    STORY_CANCER_CLASSES,
    STORY_NON_CANCER_CLASSES,
    get_parameters,
    make_hospital_loader,
    seed_everything,
    set_parameters,
    train_one_round,
)

HOSPITAL = os.getenv("HOSPITAL", "A").strip().upper()
SERVER = os.getenv("SERVER_ADDRESS", "flower-server:8080")
HUB_URL = os.getenv("HUB_URL", "http://fc-hub:8080").rstrip("/")
RUN_ID = os.getenv("RUN_ID", "local-pathmnist-ab-001")
ORG_ID = os.getenv("ORG_ID", f"org://Hospital{HOSPITAL}")

MAX_RETRIES = int(os.getenv("MAX_RETRIES", "0"))
RETRY_INTERVAL = int(os.getenv("RETRY_INTERVAL", "10"))
HUB_REGISTER_RETRY_INTERVAL = int(
    os.getenv("HUB_REGISTER_RETRY_INTERVAL", "2")
)


def now() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())


def log(message: str) -> None:
    print(f"[hospital-{HOSPITAL}:{now()}] {message}", flush=True)


def validate_cuda_runtime() -> None:
    """Require the exact CUDA-enabled stack validated on the Titan X."""

    if DEVICE.type != "cuda":
        raise RuntimeError(
            f"Flower clients require DEVICE=cuda, received {DEVICE}"
        )
    if not torch.cuda.is_available():
        raise RuntimeError(
            "CUDA GPU required but unavailable inside the Flower client. "
            "Check NVIDIA Container Toolkit and OpenTofu gpus='all'."
        )

    torch_release = torch.__version__.split("+", 1)[0]
    if torch_release != "2.2.0":
        raise RuntimeError(
            f"Expected torch 2.2.0, found {torch.__version__}"
        )
    if torch.version.cuda != "12.1":
        raise RuntimeError(
            f"Expected PyTorch CUDA runtime 12.1, found {torch.version.cuda}"
        )

    log(
        "CUDA ready: "
        f"torch={torch.__version__} "
        f"runtime={torch.version.cuda} "
        f"device={torch.cuda.get_device_name(0)} "
        f"capability={torch.cuda.get_device_capability(0)}"
    )


def validate_configuration() -> None:
    # Hospital C is intentionally not enabled in this first integration slice.
    if HOSPITAL not in {"A", "B"}:
        raise ValueError(
            f"AB_BASE supports only HOSPITAL=A or B, received {HOSPITAL!r}"
        )


def partition_metadata(counts: Dict[int, int]) -> Dict[str, Any]:
    return {
        "hospital": HOSPITAL,
        "active_labels": ACTIVE_CLASSES,
        "ignored_labels": sorted(IGNORED_CLASSES),
        "non_cancer_labels": STORY_NON_CANCER_CLASSES,
        "cancer_labels": STORY_CANCER_CLASSES,
        "cancer_samples_per_ab_hospital": (
            CANCER_SAMPLES_PER_AB_HOSPITAL
        ),
        "class_counts": {str(key): value for key, value in counts.items()},
        "flower_server": SERVER,
        "phase": "AB_BASE",
    }


def register_with_hub(counts: Dict[int, int]) -> None:
    payload = {
        "run_id": RUN_ID,
        "org_id": ORG_ID,
        "org_label": f"Hospital {HOSPITAL}",
        "data_partition": 0 if HOSPITAL == "A" else 1,
        "metadata": partition_metadata(counts),
    }

    while True:
        try:
            response = requests.post(
                f"{HUB_URL}/clients/register",
                json=payload,
                timeout=10,
            )
            response.raise_for_status()
            log(f"registered with Hub: run_id={RUN_ID} org_id={ORG_ID}")
            return
        except Exception as exc:
            log(
                "Hub registration failed: "
                f"{type(exc).__name__}: {exc}; retrying in "
                f"{HUB_REGISTER_RETRY_INTERVAL} seconds"
            )
            time.sleep(HUB_REGISTER_RETRY_INTERVAL)


class FlowerClient(fl.client.NumPyClient):
    def __init__(self) -> None:
        seed_everything()
        self.train_loader, self.counts = make_hospital_loader(HOSPITAL)
        self.model = Net().to(DEVICE)

        log(
            f"validated AB_BASE partition loaded: device={DEVICE} "
            f"samples={len(self.train_loader.dataset)} "
            f"class_counts={self.counts}"
        )

    def get_parameters(self, config):
        return get_parameters(self.model)

    def fit(self, parameters, config):
        set_parameters(self.model, parameters)
        loss, accuracy = train_one_round(self.model, self.train_loader)

        log(
            "local fit completed: "
            f"epochs={LOCAL_EPOCHS} loss={loss:.6f} "
            f"accuracy={accuracy:.6f}"
        )

        return (
            get_parameters(self.model),
            len(self.train_loader.dataset),
            {
                "hospital": HOSPITAL,
                "org_id": ORG_ID,
                "phase": "AB_BASE",
                "train_loss": float(loss),
                "train_accuracy": float(accuracy),
            },
        )


def main() -> None:
    validate_configuration()
    validate_cuda_runtime()
    client = FlowerClient()
    register_with_hub(client.counts)

    log(f"attempting Flower connection: server={SERVER}")
    attempt = 0

    while True:
        attempt += 1
        retry_limit = str(MAX_RETRIES) if MAX_RETRIES > 0 else "unlimited"
        try:
            log(f"connection attempt {attempt}/{retry_limit}")
            fl.client.start_numpy_client(
                server_address=SERVER,
                client=client,
            )
            log("Flower client completed")
            return
        except Exception as exc:
            if MAX_RETRIES > 0 and attempt >= MAX_RETRIES:
                log(
                    f"failed after {MAX_RETRIES} attempts: "
                    f"{type(exc).__name__}: {exc}"
                )
                raise
            log(
                f"connection failed: {type(exc).__name__}: {exc}; "
                f"retrying in {RETRY_INTERVAL} seconds"
            )
            time.sleep(RETRY_INTERVAL)


if __name__ == "__main__":
    main()
