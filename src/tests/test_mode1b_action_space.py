#!/usr/bin/env python3
"""Mode 1B: the hub builds Hal's action space from the Gatekeeper's source decision.
An authorised source is offered only as no_transform; without source authority Hal may
choose blur_image (still gated by unbind) or refuse; an action that wasn't offered is never
executed; nothing is asserted about the image's content. No network: Gatekeeper, Hal and
the Flower backend are stubbed."""

from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path

import pytest

SRC = Path(__file__).resolve().parents[1]
HUB_FILE = SRC / "vfp-core" / "hub" / "hub.py"
ACTORS = SRC / "vfp-core" / "issuers" / "config" / "actors.json"


@pytest.fixture(scope="module")
def hub(tmp_path_factory):
    vault = tmp_path_factory.mktemp("mode1b-hub-vault")
    os.environ["VAULT_ROOT"] = str(vault)
    os.environ["RUNS_DIR"] = str(vault / "runs")
    os.environ["ACTOR_CATALOG_PATH"] = str(ACTORS)
    spec = importlib.util.spec_from_file_location("hub_mode1b_under_test", HUB_FILE)
    module = importlib.util.module_from_spec(spec)
    sys.modules["hub_mode1b_under_test"] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def world(hub, monkeypatch):
    """source: the Gatekeeper's answer for the requester; hal_action: what Hal returns."""
    state = {"source": True, "hal_action": "no_transform", "hal_payloads": [], "admissions": [], "inferences": 0}

    def admit(principal, action, **_):
        state["admissions"].append((principal, action))
        if action == "query_model":
            return {"allow": state["source"], "decision_id": "d-" + principal}
        return {"allow": False, "decision_id": "d-" + action}  # stop the derivative path at unbind

    def decide(payload):
        state["hal_payloads"].append(payload)
        return {"action": state["hal_action"], "rationale": "", "model": "stub", "fallback": False}

    def infer(_req):
        state["inferences"] += 1
        return {"executed": True, "prediction": {"sample_image": {"image_b64": "aW1n"}}}

    monkeypatch.setattr(hub, "selected_envelope_binding_state", lambda: {"selected_envelope_id": "env-1", "bound": True})
    monkeypatch.setattr(hub, "runtime_credential", lambda *a, **k: None)
    monkeypatch.setattr(hub, "admit_principal_operation", admit)
    monkeypatch.setattr(hub, "hal_decide", decide)
    monkeypatch.setattr(hub, "mode1b_inference", infer)
    return state


def ask(hub, requester="Audrey", tissue="mucus"):
    return hub.mode1b_agent_request(
        hub.AgentMediatedInferenceRequest(requester=requester, envelope_id="env-1", requested_tissue=tissue)
    )


def test_authorised_source_is_offered_only_as_no_transform(hub, world):
    response = ask(hub)
    offered = world["hal_payloads"][0]
    assert offered["available_actions"] == ["no_transform"]
    assert "contains_cancer_related_collateral" not in offered["resource_context"]
    assert response["executed"] is True and response["representation"] == "source"
    assert response["agent_decision"]["available_actions"] == ["no_transform"]


def test_a_downgrade_that_was_not_offered_is_not_executed(hub, world):
    world["hal_action"] = "blur_image"  # a model ignoring the bounded action space
    response = ask(hub)
    assert response["executed"] is False
    assert world["inferences"] == 0
    assert ("Hal", "unbind") not in world["admissions"]


def test_without_source_authority_hal_may_blur_or_refuse(hub, world):
    world["source"], world["hal_action"] = False, "blur_image"
    response = ask(hub, tissue="colorectal_adenocarcinoma_epithelium")
    assert world["hal_payloads"][0]["available_actions"] == ["blur_image", "refuse"]
    # The derivative still needs the Gatekeeper's unbind admission (denied by the stub).
    assert ("Hal", "unbind") in world["admissions"]
    assert response["executed"] is False and response["released"] is False


def test_without_source_authority_no_transform_is_not_executed(hub, world):
    world["source"], world["hal_action"] = False, "no_transform"
    response = ask(hub, tissue="colorectal_adenocarcinoma_epithelium")
    assert response["executed"] is False
    assert world["inferences"] == 0


def test_hal_refusing_without_source_authority_runs_nothing(hub, world):
    world["source"], world["hal_action"] = False, "refuse"
    response = ask(hub, tissue="colorectal_adenocarcinoma_epithelium")
    assert response["executed"] is False and "refusal_reason" not in response
    assert world["inferences"] == 0
    assert ("Hal", "unbind") not in world["admissions"]


@pytest.mark.parametrize("reply", [None, "", " no_transform", "No_Transform", "minimal_statistics", ["no_transform"]])
@pytest.mark.parametrize("source", [True, False])
def test_a_malformed_or_unknown_action_runs_nothing(hub, world, source, reply):
    world["source"], world["hal_action"] = source, reply
    response = ask(hub)
    assert response["executed"] is False
    assert response["refusal_reason"] == "agent_action_not_offered"
    assert "prediction" not in response and "statistics" not in response
    assert world["inferences"] == 0
    assert world["admissions"] == [("Audrey", "query_model")]


@pytest.mark.parametrize("body", [None, "no_transform", ["no_transform"]])
def test_a_reply_that_is_not_an_object_is_a_gateway_error(hub, world, monkeypatch, body):
    monkeypatch.setattr(hub, "hal_decide", lambda payload: body)
    with pytest.raises(hub.HTTPException) as error:
        ask(hub)
    assert error.value.status_code == 502
    assert world["inferences"] == 0
