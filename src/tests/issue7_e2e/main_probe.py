#!/usr/bin/env python3
"""Runs the Flower server's real main() (not just the strategy) with real gRPC clients,
to check the completion report it writes. Hub calls are stubbed; the test set is a small
synthetic stand-in with PathMNIST's shape. One scenario per process.

  python main_probe.py <repo-root> <scratch-dir> <python> <ok|short|admission|missing>

'missing': only Hospital A connects; the run must fail after CLIENT_WAIT_TIMEOUT_SECONDS (15 s).
"""

import faulthandler
import importlib.util
faulthandler.dump_traceback_later(170, exit=True)
import json
import os
import platform
import socket
import subprocess
import sys
import time
from pathlib import Path

platform.architecture = lambda *a, **k: ("64bit", "")  # see round_client.py
TREE, SCRATCH, PYTHON, SCENARIO = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4]
BACKEND = TREE / "src" / "vfp-core" / "backend"
CLIENT = TREE / "src" / "tests" / "issue7_e2e" / "round_client.py"


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


grpc_port = free_port()
os.environ.update(
    VAULT_ROOT=str(SCRATCH / "vault"),
    RUNS_DIR=str(SCRATCH / "vault" / "runs"),
    RUN_ID="local-pathmnist-ab-001",
    SERVER_ADDRESS=f"127.0.0.1:{grpc_port}",
    CONTROL_HOST="127.0.0.1",
    CONTROL_PORT=str(free_port()),
    HUB_URL="http://127.0.0.1:9",
    ADMISSION_TIMEOUT_SECONDS="15",
    ROUND_TIMEOUT_SECONDS="60",
    CLIENT_WAIT_TIMEOUT_SECONDS="15",
    DEVICE="cpu",
    FLOWER_CONTROL_TOKEN="probe-control-token",
)
sys.path[:0] = [str(BACKEND), str(BACKEND / "flower_server")]
spec = importlib.util.spec_from_file_location("srv", BACKEND / "flower_server" / "server.py")
srv = importlib.util.module_from_spec(spec)
sys.modules["srv"] = srv
spec.loader.exec_module(srv)

import numpy as np  # noqa: E402
import torch  # noqa: E402
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey  # noqa: E402
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat  # noqa: E402
from torch.utils.data import DataLoader, TensorDataset  # noqa: E402

A, B = "org://HospitalA", "org://HospitalB"
keys = {org: Ed25519PrivateKey.generate() for org in (A, B, "rogue")}


def pub(org):
    import base64

    raw = keys[org].public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


ENVELOPE = "4d615116-132d-409e-8477-2bd1ce110dbf"


def fake_start():
    # What the hub's bind and START would have done.
    srv.bind_envelope(srv.EnvelopeBinding(
        envelope_id=ENVELOPE,
        policy_hash="sha256:test",
        valid_until=int(time.time()) + 3600,
        participants=[A, B],
        participant_keys={A: pub(A), B: pub(B)},
    ), "probe-control-token")
    return {"status": "running"}


class Stop(BaseException):  # like the real idle loop, never caught by main()'s error handler
    pass


def stop(*_a, **_k):
    raise Stop()


srv.register_with_hub = lambda *a, **k: None
srv.wait_for_experiment_start = fake_start
srv.fetch_experiment_config_from_hub = lambda: {"rounds": 2, "min_clients": 2, "phase": "AB_BASE"}
hub_told = []
srv.notify_hub_finished = lambda error=None: hub_told.append("fail" if error else "complete")
srv.keep_control_plane_alive = stop
srv.make_test_loader = lambda: DataLoader(
    TensorDataset(torch.rand(32, 3, 28, 28), torch.tensor(np.random.choice(list(srv.ACTIVE_CLASSES), 32)).reshape(-1, 1)), batch_size=16
)

model = srv.Net()
npz = SCRATCH / "params.npz"
np.savez(npz, *srv.get_parameters(model))

if SCENARIO == "ok":
    clients = [(A, keys[A], None), (B, keys[B], None)]
elif SCENARIO == "short":
    clients = [(A, keys[A], None), (B, keys[B], "2")]  # B fails its second fit
elif SCENARIO == "missing":
    clients = [(A, keys[A], None)]  # Hospital B never connects
else:  # admission
    clients = [(A, keys[A], None), (B, keys["rogue"], None)]

procs = []
for org, key, fail_on in clients:
    env = dict(os.environ)
    if fail_on:
        env["FAIL_ON_FIT"] = fail_on
    procs.append(subprocess.Popen(
        [PYTHON, "-W", "ignore", str(CLIENT), str(TREE), f"127.0.0.1:{grpc_port}", str(npz), org,
         key.private_bytes_raw().hex()],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ))

outcome = "returned"
started = time.monotonic()
try:
    srv.main()
except Stop:
    outcome = "idle"  # after a success or a failure alike
except Exception as exc:
    outcome = f"raised:{type(exc).__name__}"
finally:
    for p in procs:
        try:
            p.wait(timeout=20)
        except Exception:
            p.kill()

run_dir = srv.run_dir()
meta = json.loads((run_dir / "final_model_metadata.json").read_text())
manifest_path = srv.VAULT_ROOT / ENVELOPE / "run.json"
manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
with srv.training_state_lock:
    state = dict(srv.training_state)
print(json.dumps({
    "scenario": SCENARIO,
    "outcome": outcome,
    "seconds": round(time.monotonic() - started),
    "hub_told": hub_told,
    "metadata": {"status": meta.get("status"), "rounds_completed": meta.get("rounds_completed"), "error": meta.get("error")},
    "run_json": {"status": manifest.get("status"), "rounds_completed": manifest.get("rounds_completed")},
    "training_state": {"status": state.get("status"), "round": state.get("round"), "error": state.get("error")},
}), flush=True)
os._exit(0)
