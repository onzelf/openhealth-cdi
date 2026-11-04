#!/usr/bin/env python3
"""Issue #7 v0.3: failed runs end, are reported and recover, with the real hub app and the
Flower server's real main() in their own processes and real gRPC clients. No restarts.

  python lifecycle_probe.py <repo-root> <scratch-dir> <python>

Stubbed: Redis and the issuers in the hub (the envelope goes to its handle_envelope_created,
the keys come from the probe), and the server's test set (synthetic, as in main_probe.py).
Steps, as Test1F on L1-B1:
  a. Hospital A and a rogue claiming Hospital B with A's key: the rogue is refused, the run fails.
  b. Hospital A only (B registered with the hub, never connects): the run fails within
     CLIENT_WAIT_TIMEOUT_SECONDS, below Flower's sampling threshold.
  c. Hospitals A and B: the run completes.
After each failure the hub says 'failed' and the server is idle (gRPC closed, no new run);
the next START works with the same processes. About 3 minutes.
"""

import asyncio
import base64
import importlib.util
import json
import os
import socket
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

ROLE = sys.argv[1] if sys.argv[1] in ("hub", "server") else "probe"
ROOT = Path(sys.argv[2] if ROLE != "probe" else sys.argv[1])
BACKEND = ROOT / "src" / "vfp-core" / "backend"
CLIENT = Path(__file__).with_name("round_client.py")
CLIENT_WAIT = 20


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def run_hub():
    import uvicorn

    hub = load("hub", ROOT / "src" / "vfp-core" / "hub" / "hub.py")

    class NoRedis:
        async def ping(self):
            return True

        async def aclose(self):
            pass

    async def get_redis():
        return NoRedis()

    async def no_subscription():
        await asyncio.Event().wait()

    keys = json.loads(os.environ["PROBE_KEYS"])
    hub.get_redis = get_redis
    hub.subscribe_to_envelope_events = no_subscription
    hub.flower_execution_keys = lambda participants: {o: keys[o] for o in participants if o in keys}
    hub.flower_guest_execution_keys = lambda participants: {}

    @hub.app.post("/probe/envelope")
    async def probe_envelope(envelope: dict):
        await hub.handle_envelope_created(envelope)
        return {"status": "received"}

    uvicorn.run(hub.app, host="127.0.0.1", port=int(os.environ["HUB_PORT"]), log_level="warning")


def run_server():
    # Re-run by the server's own os.execv on START, with these same arguments.
    import platform

    platform.architecture = lambda *a, **k: ("64bit", "")  # see round_client.py
    sys.path[:0] = [str(BACKEND), str(BACKEND / "flower_server")]
    srv = load("srv", BACKEND / "flower_server" / "server.py")
    import numpy as np
    import torch
    from torch.utils.data import DataLoader, TensorDataset

    labels = torch.tensor(np.random.choice(list(srv.ACTIVE_CLASSES), 32)).reshape(-1, 1)
    srv.make_test_loader = lambda: DataLoader(TensorDataset(torch.rand(32, 3, 28, 28), labels), batch_size=16)
    srv.main()


if ROLE == "hub":
    run_hub()
    sys.exit(0)
if ROLE == "server":
    run_server()
    sys.exit(0)

# ---------------------------------------------------------------- the probe itself

import numpy as np  # noqa: E402
import requests  # noqa: E402
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey  # noqa: E402
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat  # noqa: E402

SCRATCH, PYTHON = Path(sys.argv[2]), sys.argv[3]
A, B = "org://HospitalA", "org://HospitalB"
RUN = "local-pathmnist-ab-001"
ENVELOPE = "6c1f4f0e-6f3b-4d0e-9a51-0f7d3c2b9a10"
key = {org: Ed25519PrivateKey.generate() for org in (A, B)}


def pub(org):
    raw = key[org].public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


hub_port, grpc_port, control_port = free_port(), free_port(), free_port()
HUB, FLOWER = f"http://127.0.0.1:{hub_port}", f"http://127.0.0.1:{control_port}"
env = dict(
    os.environ,
    RUN_ID=RUN,
    VAULT_ROOT=str(SCRATCH / "vault"),
    RUNS_DIR=str(SCRATCH / "vault" / "runs"),
    HUB_PORT=str(hub_port),
    HUB_URL=HUB,
    ACTOR_CATALOG_PATH=str(ROOT / "src" / "vfp-core" / "issuers" / "config" / "actors.json"),
    FLOWER_BACKEND_URL=FLOWER,
    BACKEND_URL=FLOWER,
    FLOWER_CONTROL_TOKEN="probe-control-token",
    PROBE_KEYS=json.dumps({A: pub(A), B: pub(B)}),
    SERVER_ADDRESS=f"127.0.0.1:{grpc_port}",
    CONTROL_HOST="127.0.0.1",
    CONTROL_PORT=str(control_port),
    CLIENT_WAIT_TIMEOUT_SECONDS=str(CLIENT_WAIT),
    ADMISSION_TIMEOUT_SECONDS="15",
    ROUND_TIMEOUT_SECONDS="60",
    DEVICE="cpu",
)
log = open(SCRATCH / "processes.log", "ab")
me = str(Path(__file__).resolve())
hub = subprocess.Popen([PYTHON, "-W", "ignore", me, "hub", str(ROOT)], env=env, stdout=log, stderr=log)
server = subprocess.Popen([PYTHON, "-W", "ignore", me, "server", str(ROOT)], env=env, stdout=log, stderr=log)
npz = SCRATCH / "params.npz"
results = {}


def check(name, ok, detail=""):
    results[name] = bool(ok)
    print(f"{'PASS' if ok else 'FAIL'} {name} {detail}".rstrip(), flush=True)


def get(url):
    return requests.get(url, timeout=5).json()


def wait(what, condition, seconds):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            value = condition()
            if value:
                return value
        except Exception:
            pass
        time.sleep(0.5)
    raise SystemExit(f"timed out: {what}")


def events(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()] if path.exists() else []


def ts(event):
    return datetime.fromisoformat(event["timestamp"]).timestamp()


def clients(*who):
    return [
        subprocess.Popen(
            [PYTHON, "-W", "ignore", str(CLIENT), str(ROOT), f"127.0.0.1:{grpc_port}", str(npz), org,
             key[signer].private_bytes_raw().hex()],
            stdout=log, stderr=log,
        )
        for org, signer in who
    ]


def grpc_closed():
    with socket.socket() as s:
        return s.connect_ex(("127.0.0.1", grpc_port)) != 0


def one_round(procs):
    """initialise, START, wait for the hub to leave 'running'; like Test1F's round."""
    before = get(f"{FLOWER}/status").get("model_run_id")
    requests.post(f"{HUB}/experiments/initialise", json={"run_id": RUN, "rounds": 1}, timeout=10).raise_for_status()
    wait("start-ready", lambda: get(f"{HUB}/experiments/{RUN}/status")["can_start"], 30)
    time.sleep(8)  # the clients import torch and Flower before they connect
    started = time.monotonic()
    assert requests.post(f"{HUB}/experiments/{RUN}/start", timeout=10).json()["status"] == "running"
    hub_status = wait(
        "the hub to leave 'running'",
        lambda: (s := get(f"{HUB}/experiments/{RUN}/status")["status"]) != "running" and s,
        150,
    )
    elapsed = time.monotonic() - started
    flower = get(f"{FLOWER}/status")
    for p in procs:  # the server released them, as after a successful run
        p.wait(timeout=30)
    run = flower["model_run_id"]
    return hub_status, flower, run, run != before, elapsed, events(SCRATCH / "vault" / "runs" / run / "events.jsonl")


def idle_after_failure(step, run):
    time.sleep(4)
    status = get(f"{HUB}/experiments/{RUN}/status")["status"]
    flower = get(f"{FLOWER}/status")
    check(f"{step}: server idle, no new run, hub still failed", grpc_closed() and status == "failed"
          and flower["model_run_id"] == run and flower["training"]["status"] == "error" and server.poll() is None,
          f"(hub={status}, model_run_id={flower['model_run_id']})")


try:
    wait("hub", lambda: get(f"{HUB}/health")["status"] == "ok", 60)
    wait("server registered", lambda: get(f"{HUB}/status")["experiment"]["flower_server_ready"], 90)
    sys.path.insert(0, str(BACKEND))
    from workloads.active import Net, get_parameters  # the server's model, for the clients' answers

    np.savez(npz, *get_parameters(Net()))
    requests.post(f"{HUB}/probe/envelope", json={
        "envelope_id": ENVELOPE, "policy_hash": "sha256:probe", "valid_until": int(time.time()) + 3600,
        "participants": [A, B],
    }, timeout=10).raise_for_status()
    wait("bound", lambda: get(f"{FLOWER}/status")["bound_envelope"]["envelope_id"] == ENVELOPE, 30)
    for org in (A, B):  # as the real clients do when they start; B then goes missing
        requests.post(f"{HUB}/clients/register", json={"run_id": RUN, "org_id": org}, timeout=10).raise_for_status()

    # a. A rogue claiming Hospital B, signing with Hospital A's key
    hub_status, flower, run, new, elapsed, ev = one_round(clients((A, A), (B, A)))
    refused = [e["reason"] for e in ev if e["event_type"] == "flower_client_rejected"]
    check("a: rogue refused, run failed closed, hub says failed",
          new and hub_status == "failed" and flower["training"]["status"] == "error"
          and "invalid_proof:org://HospitalB" in refused
          and any(e["event_type"] == "round_admission_failed" for e in ev)
          and not any(e["event_type"] == "round_fit_aggregated" for e in ev),
          f"(run {run}, hub={hub_status}, refused={sorted(set(refused))}, {elapsed:.0f} s)")
    idle_after_failure("a", run)

    # b. Hospital B never connects: one client, two required
    hub_status, flower, run, new, elapsed, ev = one_round(clients((A, A)))
    configured = [ts(e) for e in ev if e["event_type"] == "round_fit_configured"]
    missing = [e for e in ev if e["event_type"] == "round_clients_missing"]
    waited = ts(missing[0]) - configured[0] if missing and configured else -1
    check("b: missing hospital failed in bounded time, hub says failed",
          new and hub_status == "failed" and flower["training"]["status"] == "error"
          and missing and missing[0]["connected"] == 1 and missing[0]["required"] == 2
          and CLIENT_WAIT - 1 <= waited <= CLIENT_WAIT + 5 and elapsed < CLIENT_WAIT + 40
          and not any(e["event_type"] == "round_fit_aggregated" for e in ev),
          f"(run {run}, waited {waited:.1f} s for clients, {elapsed:.0f} s START to failed)")
    idle_after_failure("b", run)

    # c. The A+B happy path, same processes
    hub_status, flower, run, new, elapsed, ev = one_round(clients((A, A), (B, B)))
    manifest = json.loads((SCRATCH / "vault" / ENVELOPE / "run.json").read_text())
    admitted = [e["participants"] for e in ev if e["event_type"] == "round_clients_admitted"]
    check("c: A+B run completed, hub says completed",
          new and hub_status == "completed" and flower["training"]["status"] == "done"
          and admitted == [[A, B]] and manifest["status"] == "completed" and manifest["rounds_completed"] == 1,
          f"(run {run}, hub={hub_status}, admitted={admitted}, {elapsed:.0f} s)")

    starts = [e for e in events(SCRATCH / "vault" / "runs" / RUN / "events.jsonl")
              if e["event_type"] == "server_starting"]
    check("no restarts: hub and server processes alive throughout",
          hub.poll() is None and server.poll() is None and len(starts) == 3,
          f"(server pid {server.pid}; {len(starts)} starts: the first, then its own re-exec on START 2 and 3)")
finally:
    for p in (server, hub):
        p.kill()

print(json.dumps(results))
sys.exit(0 if len(results) == 6 and all(results.values()) else 1)
