#!/usr/bin/env python3
"""Issue #7 end to end over real Flower 1.28 gRPC on localhost (no Docker, no hub).

The server side is the real EvidenceFedAvg from flower_server/server.py (admission,
expiry, accounting). Each client is a separate process that answers the challenge with
the real flower_client/client.py get_properties code. About a minute in total.

  python round_probe.py <repo-root> <scratch-dir> <python>

Scenarios:
  1. A+B run with two rogues (wrong key claiming A, no key claiming B): only A and B train.
  2. Mode 1A with the guest key registered by A: A, B and C train.
  3. Only A plus a rogue claiming B: the round fails closed, nothing aggregated.
"""

from __future__ import annotations

import importlib.util
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT, SCRATCH, PYTHON = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
BACKEND = ROOT / "src" / "vfp-core" / "backend"
CLIENT = Path(__file__).with_name("round_client.py")
SCENARIO = sys.argv[4] if len(sys.argv) > 4 else "all"

os.environ.update(
    VAULT_ROOT=str(SCRATCH / "vault"),
    RUNS_DIR=str(SCRATCH / "vault" / "runs"),
    RUN_ID="local-pathmnist-ab-001",
    ADMISSION_TIMEOUT_SECONDS="20",
)
sys.path[:0] = [str(BACKEND), str(BACKEND / "flower_server")]
spec = importlib.util.spec_from_file_location("srv", BACKEND / "flower_server" / "server.py")
srv = importlib.util.module_from_spec(spec)
sys.modules["srv"] = srv
spec.loader.exec_module(srv)
srv.control_run_dir()

import flwr as fl  # noqa: E402
import numpy as np  # noqa: E402
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey  # noqa: E402
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat  # noqa: E402
from flwr.common import ndarrays_to_parameters  # noqa: E402

A, B, C = "org://HospitalA", "org://HospitalB", "org://HospitalC"
seed = {org: Ed25519PrivateKey.generate() for org in (A, B, C, "rogue")}


def pub(org):
    import base64

    raw = seed[org].public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def hexkey(org):
    return seed[org].private_bytes_raw().hex()


model = srv.Net()
arrays = srv.get_parameters(model)
npz = SCRATCH / "params.npz"
np.savez(npz, *arrays)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def run(min_clients, guest_admitted, clients):
    with srv.bound_envelope_lock:
        srv.bound_envelope = {
            "envelope_id": "env-e2e",
            "valid_until": time.time() + 3600,
            "participants": [A, B],
            "participant_keys": {A: pub(A), B: pub(B)},
            "guest_keys": {C: pub(C)},
        }
    strategy = srv.EvidenceFedAvg(
        model=srv.Net(),
        expected_rounds=1,
        min_fit_clients=min_clients,
        # Wait until every launched client (rogues included) is connected, so each
        # scenario challenges all of them in the same round.
        min_available_clients=len(clients),
        fraction_fit=1.0,
        fraction_evaluate=0.0,
        guest_admitted=guest_admitted,
        initial_parameters=ndarrays_to_parameters(arrays),
    )
    address = f"127.0.0.1:{free_port()}"
    procs = [
        subprocess.Popen(
            [PYTHON, "-W", "ignore", str(CLIENT), str(ROOT), address, str(npz), org_id, key_hex],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        for org_id, key_hex in clients
    ]
    error = None
    try:
        fl.server.start_server(
            server_address=address,
            config=fl.server.ServerConfig(num_rounds=1, round_timeout=60),
            strategy=strategy,
        )
    except Exception as exc:  # the fail-closed scenario ends here
        error = exc
    finally:
        for p in procs:
            try:
                p.wait(timeout=15)
            except Exception:
                p.kill()
    return strategy, error


def last_events(n=40):
    path = srv.run_dir() / "events.jsonl"
    lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
    return "\n".join(lines[-n:])


results = {}

if SCENARIO in ("all", "1"):
    s, err = run(2, False, [(A, hexkey(A)), (B, hexkey(B)), (A, hexkey("rogue")), (B, "")])
    admitted = sorted(s.admitted.get(1, {}).values())
    ev = last_events()
    results["1_ab_with_rogues"] = (
        err is None and admitted == [A, B] and s.rounds_aggregated == 1
        and ev.count("flower_client_rejected") >= 2
    )
    print("scenario 1:", "PASS" if results["1_ab_with_rogues"] else "FAIL", admitted, s.rounds_aggregated, repr(err), flush=True)

if SCENARIO in ("all", "2"):
    s, err = run(3, True, [(A, hexkey(A)), (B, hexkey(B)), (C, hexkey(C))])
    admitted = sorted(s.admitted.get(1, {}).values())
    results["2_mode1a_guest"] = err is None and admitted == [A, B, C] and s.rounds_aggregated == 1
    print("scenario 2:", "PASS" if results["2_mode1a_guest"] else "FAIL", admitted, s.rounds_aggregated, repr(err), flush=True)

if SCENARIO in ("all", "3"):
    s, err = run(2, False, [(A, hexkey(A)), (B, hexkey("rogue"))])
    results["3_fail_closed"] = (
        isinstance(err, srv.AdmissionThresholdNotMet) and s.rounds_aggregated == 0
        and "round_admission_failed" in last_events()
    )
    print("scenario 3:", "PASS" if results["3_fail_closed"] else "FAIL", repr(err)[:120], s.rounds_aggregated, flush=True)

print(json.dumps(results))
os._exit(0 if results and all(results.values()) else 1)
