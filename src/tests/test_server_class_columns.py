#!/usr/bin/env python3
"""Checks the per-class recall columns are unchanged for PathMNIST."""

from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1] / "vfp-core" / "backend"
sys.path.insert(0, str(BACKEND))

ORIGINAL_HEADER = [
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
ORIGINAL_STATE_KEYS = [
    "status",
    "phase",
    "data_partition_profile",
    "data_partition_seed",
    "round",
    "rounds",
    "min_clients",
    "guest_admission_decision_id",
    "guest_admission_run_id",
    "overall_accuracy",
    "macro_recall",
    "non_cancer_recall",
    "cancer_recall",
    "cancer_f1",
    "class_7_recall",
    "class_8_recall",
    "error",
]


def main() -> None:
    tmp = tempfile.mkdtemp()
    os.environ.pop("WORKLOAD", None)
    os.environ.setdefault("MEDMNIST_ROOT", tmp)
    os.environ["RUNS_DIR"] = os.environ["VAULT_ROOT"] = tmp
    spec = importlib.util.spec_from_file_location(
        "server_under_test", BACKEND / "flower_server" / "server.py"
    )
    server = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(server)
    except ImportError as exc:
        print(f"SKIP: server dependencies missing ({exc})")
        return

    recalls = [i / 10 for i in range(9)]
    assert list(server.cancer_class_recalls(recalls).items()) == [
        ("class_7_recall", 0.7),
        ("class_8_recall", 0.8),
    ]
    assert list(server.training_state) == ORIGINAL_STATE_KEYS

    target = Path(tmp) / "metrics.csv"
    server.metrics_path = lambda: target
    server.ensure_metrics_header()
    assert target.read_text().splitlines()[0].split(",") == ORIGINAL_HEADER
    print("PASS: PathMNIST metrics columns and state keys are unchanged")


if __name__ == "__main__":
    main()
