#!/usr/bin/env python3
"""A7 rogue Hospital C Flower selection probe.

This deliberately skips both OpenHealth client-side gates:
- wait_for_mode1a_training_admission()
- register_with_hub()

The probe uses the real Hospital C model/partition implementation so the
unchanged Flower server sees a protocol-valid client.  It writes evidence and
raises immediately when fit() is invoked.  No rogue model update is returned.
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

import flwr as fl

# The real OpenHealth client module lives at /app/client.py.
# This helper is executed from /audit, so make /app importable explicitly.
sys.path.insert(0, "/app")
import client as openhealth_client


OUT = Path("/audit/out")
MARKER = OUT / "fit-called.json"


def mark(event: str, config: dict | None = None) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    MARKER.write_text(
        json.dumps(
            {
                "event": event,
                "hospital": openhealth_client.HOSPITAL,
                "org_id": openhealth_client.ORG_ID,
                "run_id": openhealth_client.RUN_ID,
                "server": openhealth_client.SERVER,
                "pid": os.getpid(),
                "timestamp": time.time(),
                "fit_config": config or {},
                "bypassed": [
                    "wait_for_mode1a_training_admission",
                    "register_with_hub",
                ],
            },
            indent=2,
            sort_keys=True,
        ),
        encoding="utf-8",
    )


class RogueCProbe(openhealth_client.FlowerClient):
    def fit(self, parameters, config):
        mark("fit_called", dict(config or {}))
        raise RuntimeError(
            "A7_PROBE_ABORT: rogue Hospital C was selected for AB_BASE fit"
        )


def main() -> None:
    if openhealth_client.HOSPITAL != "C":
        raise RuntimeError(
            f"A7 requires HOSPITAL=C, got {openhealth_client.HOSPITAL!r}"
        )

    openhealth_client.validate_configuration()
    openhealth_client.validate_cuda_runtime()

    probe = RogueCProbe()

    # Intentionally absent:
    #   openhealth_client.wait_for_mode1a_training_admission()
    #   openhealth_client.register_with_hub(probe.counts)

    attempt = 0
    while True:
        attempt += 1
        openhealth_client.log(
            "A7 rogue connection attempt "
            f"{attempt}: bypassing Hub registration and Mode1A admission"
        )
        try:
            fl.client.start_numpy_client(
                server_address=openhealth_client.SERVER,
                client=probe,
            )
        except Exception as exc:
            if MARKER.exists():
                # fit() was invoked. The shell harness already has the evidence.
                openhealth_client.log(f"A7 selection proved: {exc}")
                return
            openhealth_client.log(
                f"A7 connection not selected yet: {type(exc).__name__}: {exc}"
            )
            time.sleep(1)
        else:
            if MARKER.exists():
                return
            time.sleep(1)


if __name__ == "__main__":
    main()
