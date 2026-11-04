#!/usr/bin/env python3
"""Issue #7 v0.2: the hub hands Flower each admitted organisation's execution key, and a
sponsored guest's key only from its sponsor's issuer; it presents the control token only to
the configured Flower server; v0.3: a failed run is recorded as failed. No network: issuer
replies are stubbed."""

from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path

import pytest

SRC = Path(__file__).resolve().parents[1]
HUB_FILE = SRC / "vfp-core" / "hub" / "hub.py"
ACTORS = SRC / "vfp-core" / "issuers" / "config" / "actors.json"
A, B, C = "org://HospitalA", "org://HospitalB", "org://HospitalC"


@pytest.fixture(scope="module")
def hub(tmp_path_factory):
    vault = tmp_path_factory.mktemp("i7-hub-vault")
    os.environ["VAULT_ROOT"] = str(vault)
    os.environ["RUNS_DIR"] = str(vault / "runs")
    os.environ["ACTOR_CATALOG_PATH"] = str(ACTORS)
    spec = importlib.util.spec_from_file_location("hub_i7_under_test", HUB_FILE)
    module = importlib.util.module_from_spec(spec)
    sys.modules["hub_i7_under_test"] = module
    spec.loader.exec_module(module)
    return module


REGISTRIES = {
    A: [
        {"sub": "Audrey", "org_id": A, "pub_b64": "audrey"},
        {"sub": "flower-execution", "org_id": A, "pub_b64": "key-a"},
        {"sub": "flower-execution-guest-HospitalC", "org_id": A, "pub_b64": "key-c"},
    ],
    B: [
        {"sub": "flower-execution", "org_id": B, "pub_b64": "key-b"},
        # B cannot register a key for A's guest, nor one for A.
        {"sub": "flower-execution-guest-HospitalC", "org_id": B, "pub_b64": "forged-c"},
        {"sub": "flower-execution", "org_id": A, "pub_b64": "forged-a"},
    ],
}


@pytest.fixture
def issuers(hub, monkeypatch):
    by_url = {hub.ISSUER_URLS[A]: REGISTRIES[A], hub.ISSUER_URLS[B]: REGISTRIES[B]}
    monkeypatch.setattr(hub, "issuer_members", lambda url: by_url.get(url, []))


def test_participant_keys_come_from_each_organisations_own_issuer(hub, issuers):
    assert hub.flower_execution_keys([A, B]) == {A: "key-a", B: "key-b"}
    assert hub.flower_execution_keys([B]) == {B: "key-b"}


def test_guest_key_comes_only_from_the_sponsors_issuer(hub, issuers):
    assert hub.flower_guest_execution_keys([A, B]) == {C: "key-c"}


def test_no_guest_key_when_the_sponsor_is_not_a_participant(hub, issuers):
    assert hub.flower_guest_execution_keys([B]) == {}


def test_control_token_goes_only_to_the_configured_flower_server(hub, monkeypatch):
    monkeypatch.setattr(hub, "FLOWER_CONTROL_TOKEN", "the-hubs-token")
    monkeypatch.setattr(hub, "FLOWER_BACKEND_URL", "http://flower-server:8081")
    assert hub.flower_control_headers("http://flower-server:8081/") == {"X-OpenHealth-Control-Token": "the-hubs-token"}
    # A backend that registered itself with another URL never receives the token.
    assert hub.flower_control_headers("http://attacker:8081") == {}
    monkeypatch.setattr(hub, "FLOWER_CONTROL_TOKEN", "")
    assert hub.flower_control_headers("http://flower-server:8081") == {}


def test_failed_run_is_reported_failed_and_a_new_run_can_start(hub):
    run_id = hub.experiment_state["run_id"]
    hub.experiment_state["status"] = "running"
    reply = hub.experiment_fail(run_id, hub.ExperimentFailure(error="round 1: 1 client(s) connected"))
    assert reply["status"] == "failed" and hub.experiment_status(run_id)["status"] == "failed"
    assert '"experiment_failed"' in (hub.run_dir(run_id) / "events.jsonl").read_text(encoding="utf-8")
    # Recovery is the normal one: initialise, then START (no restart).
    hub.experiments_initialise(hub.ExperimentInitialiseRequest(run_id=run_id))
    assert hub.experiment_status(run_id)["status"] == "waiting"
