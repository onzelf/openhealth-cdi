#!/usr/bin/env python3
"""Issue #7 v0.2 checks: per-round envelope expiry, the Mode 1A guest key, honest
round accounting, the client's execution key, parallel challenges and the control token;
v0.3: a missing hospital fails the round in bounded time, a failed run ends cleanly and is
reported to the hub as failed.

Runs without Flower networking: the strategy's configure_fit is driven with stand-in
client proxies that answer the challenge like the real client does.
"""

from __future__ import annotations

import base64
import importlib.util
import json
import os
import sys
import time
from pathlib import Path
from types import SimpleNamespace

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

SRC = Path(__file__).resolve().parents[1]
BACKEND = SRC / "vfp-core" / "backend"
SERVER_DIR = BACKEND / "flower_server"
CLIENT_FILE = BACKEND / "flower_client" / "client.py"

A, B, C = "org://HospitalA", "org://HospitalB", "org://HospitalC"


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def public(key: Ed25519PrivateKey) -> str:
    return b64url(key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw))


@pytest.fixture(scope="module")
def server(tmp_path_factory):
    vault = tmp_path_factory.mktemp("i7-vault")
    os.environ["VAULT_ROOT"] = str(vault)
    os.environ["RUNS_DIR"] = str(vault / "runs")
    os.environ["RUN_ID"] = "local-pathmnist-ab-001"
    os.environ["ADMISSION_TIMEOUT_SECONDS"] = "0"
    for path in (str(BACKEND), str(SERVER_DIR)):
        if path not in sys.path:
            sys.path.insert(0, path)
    spec = importlib.util.spec_from_file_location("server_i7_under_test", SERVER_DIR / "server.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["server_i7_under_test"] = module
    spec.loader.exec_module(module)
    module.control_run_dir()
    return module


@pytest.fixture(scope="module")
def keys():
    return {org: Ed25519PrivateKey.generate() for org in (A, B, C, "rogue")}


class Proxy:
    """Answers the challenge like flower_client/client.py's get_properties."""

    def __init__(self, cid, org, key, admission):
        self.cid, self.org, self.key, self.admission = cid, org, key, admission

    def get_properties(self, ins, timeout, group_id):
        config = ins.config
        message = self.admission.challenge_message(
            config["envelope_id"], config["run_id"], config["round"],
            config["admission_nonce"], self.org,
        )
        return SimpleNamespace(properties={
            "org_id": self.org,
            "admission_signature": b64url(self.key.sign(message)),
        })


def bind(server, envelope, valid_until, keys, guest=True):
    binding = {
        "envelope_id": envelope,
        "valid_until": valid_until,
        "participants": [A, B],
        "participant_keys": {A: public(keys[A]), B: public(keys[B])},
        "guest_keys": {C: public(keys[C])} if guest else {},
    }
    with server.bound_envelope_lock:
        server.bound_envelope = binding


def strategy(server, min_clients, guest_admitted=False):
    from flwr.common import ndarrays_to_parameters

    model = server.Net()
    return server.EvidenceFedAvg(
        model=model,
        expected_rounds=2,
        min_fit_clients=min_clients,
        min_available_clients=min_clients,
        guest_admitted=guest_admitted,
        initial_parameters=ndarrays_to_parameters(server.get_parameters(model)),
    )


def offer(monkeypatch, proxies):
    """Make FedAvg.configure_fit hand our proxies to the admission step."""
    from flwr.server.strategy import FedAvg

    monkeypatch.setattr(FedAvg, "configure_fit", lambda self, rnd, params, cm: [(p, "fit-ins") for p in proxies])


def events(server):
    path = server.run_dir() / "events.jsonl"
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


# ------------------------------------------------------------ per-round envelope expiry

def test_expired_envelope_stops_the_round(server, keys, monkeypatch):
    bind(server, "env-expired", time.time() - 1, keys)
    offer(monkeypatch, [])  # never reached: expiry is checked before any client is asked
    with pytest.raises(server.EnvelopeExpired):
        strategy(server, 2).configure_fit(3, None, None)
    assert "round_envelope_expired" in json.dumps(events(server))


def test_unreadable_expiry_fails_closed_and_missing_expiry_does_not(server):
    import admission

    assert admission.envelope_expired("not-a-time", time.time()) is True
    assert admission.envelope_expired(None, time.time()) is False
    assert admission.envelope_expired(time.time() + 60, time.time()) is False


# ------------------------------------------------------------ admission: A and B, rogue refused, guest only when admitted

def test_participants_admitted_rogue_and_guest_refused_on_ab_run(server, keys, monkeypatch):
    import admission

    bind(server, "env-ab", time.time() + 600, keys)
    proxies = [
        Proxy("a", A, keys[A], admission),
        Proxy("b", B, keys[B], admission),
        Proxy("rogue-a", A, keys["rogue"], admission),
        Proxy("c", C, keys[C], admission),
    ]
    offer(monkeypatch, proxies)
    run = strategy(server, 2, guest_admitted=False)
    admitted = run.configure_fit(1, None, None)
    assert [p.cid for p, _ in admitted] == ["a", "b"]
    assert run.admitted[1] == {"a": A, "b": B}
    text = json.dumps(events(server))
    assert "invalid_proof:org://HospitalA" in text  # the rogue
    assert "invalid_proof:org://HospitalC" in text  # the guest on an A+B run


def test_guest_admitted_on_mode1a_run(server, keys, monkeypatch):
    import admission

    bind(server, "env-1a", time.time() + 600, keys)
    proxies = [Proxy(cid, org, keys[org], admission) for cid, org in (("a", A), ("b", B), ("c", C))]
    offer(monkeypatch, proxies)
    run = strategy(server, 3, guest_admitted=True)
    admitted = run.configure_fit(1, None, None)
    assert sorted(run.admitted[1].values()) == [A, B, C] and len(admitted) == 3


def test_guest_key_unused_when_sponsor_registered_none(server, keys, monkeypatch):
    import admission

    bind(server, "env-1a-nokey", time.time() + 600, keys, guest=False)
    proxies = [Proxy(cid, org, keys[org], admission) for cid, org in (("a", A), ("b", B), ("c", C))]
    offer(monkeypatch, proxies)
    with pytest.raises(admission.AdmissionThresholdNotMet):
        strategy(server, 3, guest_admitted=True).configure_fit(1, None, None)


def test_too_few_proven_clients_fail_closed(server, keys, monkeypatch):
    import admission

    bind(server, "env-short", time.time() + 600, keys)
    offer(monkeypatch, [Proxy("a", A, keys[A], admission), Proxy("rogue-b", B, keys["rogue"], admission)])
    with pytest.raises(admission.AdmissionThresholdNotMet):
        strategy(server, 2).configure_fit(1, None, None)


# ------------------------------------------------------------ honest round accounting

def test_rounds_counted_only_when_aggregated_and_short_rounds_recorded(server):
    from flwr.common import Code, FitRes, Status, ndarrays_to_parameters

    run = strategy(server, 2)
    good = server.get_parameters(run.model)

    def res():
        return FitRes(status=Status(Code.OK, ""), parameters=ndarrays_to_parameters(good), num_examples=10, metrics={})

    run.admitted[1] = {"a": A, "b": B}
    run.aggregate_fit(1, [(SimpleNamespace(cid="a"), res()), (SimpleNamespace(cid="b"), res())], [])
    run.admitted[2] = {"a": A, "b": B}
    run.aggregate_fit(2, [(SimpleNamespace(cid="a"), res())], [RuntimeError("b timed out")])
    assert run.rounds_aggregated == 2
    assert run.short_rounds == [2]


def test_round_timeout_is_passed_to_flower(server):
    source = (SERVER_DIR / "server.py").read_text(encoding="utf-8")
    assert "round_timeout=ROUND_TIMEOUT_SECONDS" in source and server.ROUND_TIMEOUT_SECONDS > 0


# ------------------------------------------------------------ the client's key and signature

def test_client_reads_its_key_file_and_signs_a_verifiable_answer(server, tmp_path, monkeypatch):
    import admission

    key = Ed25519PrivateKey.generate()
    seed = key.private_bytes_raw().hex()
    key_file = tmp_path / "execution.key"
    key_file.write_text(seed + "\n")
    monkeypatch.delenv("EXECUTION_KEY_HEX", raising=False)
    monkeypatch.setenv("EXECUTION_KEY_FILE", str(key_file))
    monkeypatch.setenv("ORG_ID", A)
    spec = importlib.util.spec_from_file_location("client_i7_under_test", CLIENT_FILE)
    client = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(client)
    assert client.EXECUTION_KEY_HEX == seed

    config = {"admission_nonce": "n-1", "envelope_id": "env-x", "run_id": "r-1", "round": 4}
    answer = client.FlowerClient.get_properties(None, config)
    assert admission.verified_org(answer, {A: public(key)}, "env-x", "r-1", 4, "n-1") == A
    # The same answer is no good for another round or nonce.
    assert admission.verified_org(answer, {A: public(key)}, "env-x", "r-1", 5, "n-1") is None


# ------------------------------------------------------------ silent clients cost one timeout, not one each

class SilentProxy:
    """Reaches the server but never answers the challenge in time."""

    def __init__(self, cid, delay):
        self.cid, self.delay = cid, delay

    def get_properties(self, ins, timeout, group_id):
        time.sleep(self.delay)
        raise TimeoutError("no answer")


def test_silent_clients_are_challenged_in_parallel(server, keys):
    import admission

    participant_keys = {A: public(keys[A]), B: public(keys[B])}
    silent = [SilentProxy(f"silent-{i}", 0.5) for i in range(8)]
    proxies = silent[:4] + [Proxy("a", A, keys[A], admission), Proxy("b", B, keys[B], admission)] + silent[4:]
    started = time.monotonic()
    admitted, orgs, rejected = admission.admit(
        [(p, "fit-ins") for p in proxies], participant_keys, "env-par", "run-par", 1
    )
    elapsed = time.monotonic() - started
    assert elapsed < 2.0, elapsed  # serially it would take 8 x 0.5 s
    assert [p.cid for p, _ in admitted] == ["a", "b"]
    assert sorted(cid for cid, _ in rejected) == sorted(p.cid for p in silent)
    assert all(reason == "no_proof:TimeoutError" for _, reason in rejected)


def test_duplicates_still_resolved_in_sampling_order(server, keys):
    import admission

    participant_keys = {A: public(keys[A]), B: public(keys[B])}
    proxies = [Proxy("a-1", A, keys[A], admission), Proxy("a-2", A, keys[A], admission), Proxy("b", B, keys[B], admission)]
    admitted, orgs, rejected = admission.admit(
        [(p, "fit-ins") for p in proxies], participant_keys, "env-dup", "run-dup", 1
    )
    assert orgs == {"a-1": A, "b": B}
    assert rejected == [("a-2", "duplicate_org:org://HospitalA")]


# ------------------------------------------------------------ only the hub can set the trusted keys

def test_bind_envelope_requires_the_control_token(server, monkeypatch):
    from fastapi import HTTPException

    binding = server.EnvelopeBinding(
        envelope_id="env-token", policy_hash="sha256:test", valid_until=int(time.time()) + 600,
        participants=[A], participant_keys={A: "attacker-key"},
    )
    monkeypatch.setattr(server, "CONTROL_TOKEN", "")
    with pytest.raises(HTTPException) as unset:
        server.bind_envelope(binding, "anything")
    assert unset.value.status_code == 503  # not configured: nothing can bind

    monkeypatch.setattr(server, "CONTROL_TOKEN", "the-hubs-token")
    for presented in ("", "wrong-token", "the-hubs-toke"):
        with pytest.raises(HTTPException) as refused:
            server.bind_envelope(binding, presented)
        assert refused.value.status_code == 401
    with server.bound_envelope_lock:
        assert (server.bound_envelope or {}).get("envelope_id") != "env-token"

    assert server.bind_envelope(binding, "the-hubs-token")["status"] == "bound"
    with server.bound_envelope_lock:
        assert server.bound_envelope["participant_keys"] == {A: "attacker-key"}


def test_control_token_read_from_env_or_file(server, tmp_path, monkeypatch):
    token_file = tmp_path / "flower_control.token"
    token_file.write_text("from-file\n", encoding="utf-8")
    monkeypatch.delenv("FLOWER_CONTROL_TOKEN", raising=False)
    monkeypatch.setenv("FLOWER_CONTROL_TOKEN_FILE", str(token_file))
    assert server.load_control_token() == "from-file"
    monkeypatch.setenv("FLOWER_CONTROL_TOKEN", "from-env")
    assert server.load_control_token() == "from-env"
    monkeypatch.delenv("FLOWER_CONTROL_TOKEN")
    monkeypatch.setenv("FLOWER_CONTROL_TOKEN_FILE", str(tmp_path / "missing"))
    assert server.load_control_token() == ""


# ------------------------------------------------------------ v0.3: a missing hospital fails in bounded time

def test_missing_hospital_fails_the_round_in_bounded_time(server, keys, monkeypatch):
    import admission

    bind(server, "env-missing", time.time() + 600, keys)
    monkeypatch.setattr(server, "CLIENT_WAIT_TIMEOUT_SECONDS", 0.5)
    manager = server.BoundedClientManager()
    manager.register(Proxy("a", A, keys[A], admission))  # Hospital B never connects
    started = time.monotonic()
    with pytest.raises(admission.AdmissionThresholdNotMet, match="1 client"):
        strategy(server, 2).configure_fit(1, None, manager)  # Flower's own wait is 24 h
    assert time.monotonic() - started < 3
    missing = [e for e in events(server) if e["event_type"] == "round_clients_missing"]
    assert missing[-1]["connected"] == 1 and missing[-1]["required"] == 2


# ------------------------------------------------------------ v0.3: a failed run ends cleanly and is reported as failed

def test_failed_run_ends_like_a_successful_one(server, keys, monkeypatch):
    from flwr.server.client_manager import SimpleClientManager
    from flwr.server.server import run_fl  # what start_server() runs before it stops gRPC

    bind(server, "env-ends", time.time() - 1, keys)  # round 1 raises EnvelopeExpired
    flower = server.CleanStopServer(client_manager=SimpleClientManager(), strategy=strategy(server, 2))
    disconnected = []
    monkeypatch.setattr(flower, "disconnect_all_clients", lambda timeout: disconnected.append(timeout))
    run_fl(flower, server.fl.server.ServerConfig(num_rounds=2, round_timeout=5))
    assert isinstance(flower.error, server.EnvelopeExpired)
    assert disconnected == [5]  # the clients are released as after a successful run


def test_hub_is_told_failed_never_completed(server, monkeypatch):
    posts = []

    def post(url, json=None, timeout=None):
        posts.append((url.rsplit("/", 1)[-1], json))
        return SimpleNamespace(raise_for_status=lambda: None, json=lambda: {})

    monkeypatch.setattr(server.requests, "post", post)
    server.notify_hub_finished("round 1: 1 client(s) connected within 300 s, 2 required")
    server.notify_hub_finished("rounds_aggregated=1/2;short_rounds=[2]")
    server.notify_hub_finished(None)
    assert posts == [
        ("fail", {"error": "round 1: 1 client(s) connected within 300 s, 2 required"}),
        ("fail", {"error": "rounds_aggregated=1/2;short_rounds=[2]"}),
        ("complete", None),
    ]


def test_any_failure_after_start_is_reported_as_failed(server, monkeypatch):
    posts, written = [], []

    def post(url, json=None, timeout=None):
        posts.append((url.rsplit("/", 1)[-1], json))
        return SimpleNamespace(raise_for_status=lambda: None, json=lambda: {})

    monkeypatch.setattr(server.requests, "post", post)
    monkeypatch.setattr(server, "write_final_metadata", lambda **kw: written.append(kw))
    with server.bound_envelope_lock:
        server.bound_envelope = None
    run = {}
    with pytest.raises(RuntimeError, match="without a bound envelope") as failure:
        server.run_training(run)  # fails during setup, before a run exists
    server.report_failed_run(failure.value, run)
    server.report_failed_run(AssertionError(), {})  # an exception without a message
    assert posts == [
        ("fail", {"error": "Experiment activated without a bound envelope"}),
        ("fail", {"error": "AssertionError"}),
    ]
    assert written == []  # no run of this START, so the previous run's evidence is left alone
    assert server.training_state["status"] == "error"
