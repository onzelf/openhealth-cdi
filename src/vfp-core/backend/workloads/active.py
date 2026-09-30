#!/usr/bin/env python3
"""The workload the Flower client and server run (PathMNIST by default)."""

from __future__ import annotations

import importlib
import os

from workloads import DEFAULT_WORKLOAD, REQUIRED_NAMES, WORKLOADS

WORKLOAD = (
    os.getenv("WORKLOAD", DEFAULT_WORKLOAD).strip().lower() or DEFAULT_WORKLOAD
)

# Only registered names can be loaded, never an arbitrary module.
if WORKLOAD not in WORKLOADS:
    raise RuntimeError(
        f"Unknown WORKLOAD={WORKLOAD!r}. Known workloads: {sorted(WORKLOADS)}"
    )

_workload_module = importlib.import_module(WORKLOADS[WORKLOAD])

_missing_names = [
    name for name in REQUIRED_NAMES if not hasattr(_workload_module, name)
]
if _missing_names:
    raise RuntimeError(
        f"Workload {WORKLOAD!r} does not export required names: "
        f"{_missing_names}"
    )

globals().update(
    {name: getattr(_workload_module, name) for name in REQUIRED_NAMES}
)
