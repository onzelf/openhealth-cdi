#!/usr/bin/env python3

from __future__ import annotations

import ast
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def function_source(source: str, name: str) -> str:
    tree = ast.parse(source)
    lines = source.splitlines()
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == name:
            end = getattr(node, "end_lineno", None)
            if end is None:
                raise AssertionError(f"{name}: Python parser did not provide end_lineno")
            return "\n".join(lines[node.lineno - 1:end])
    raise AssertionError(f"missing function: {name}")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)
    print(f"GREEN  {message}")


main_tf = read("src/infra/tofu/main.tf")
hub = read("src/vfp-core/hub/hub.py")
flower = read("src/vfp-core/backend/flower_server/server.py")
demo_start = read("src/tools/demo_start.sh")
preflight = read("src/tests/Test0B_delivery_preflight.sh")


# 1. Generic human signer is no longer a deployed component.
require(
    "holder-signer" not in main_tf
    and 'resource "docker_image" "holder_signer"' not in main_tf
    and 'resource "docker_container" "holder_signer"' not in main_tf,
    "OpenTofu does not deploy holder-signer",
)

require(
    "holder-signer" not in demo_start
    and "holder-signer" not in preflight,
    "startup and delivery preflight do not require holder-signer",
)


# 2. Hub cannot fall back to a generic signer.
require(
    "SIGNER_URL" not in hub,
    "Hub has no generic SIGNER_URL fallback",
)

signer = function_source(hub, "sign_principal_dpop")
require(
    "signer_url: str" in signer
    and "SIGNER_URL or" not in signer,
    "DPoP helper requires an explicit signer endpoint",
)


# 3. Mode 1A consumes Charlie's presented holder evidence.
mode1a = function_source(hub, "mode1a_guest_contribution_admission")
require(
    'alias="Authorization"' in mode1a
    and 'alias="DPoP"' in mode1a
    and 'alias="X-DPoP-Nonce"' in mode1a,
    "Mode 1A accepts holder-supplied ECT and DPoP evidence",
)

require(
    "holder_runtime_credentials" not in mode1a
    and "SIGNER_URL" not in mode1a
    and "sign_principal_dpop" not in mode1a,
    "Mode 1A does not recover or manufacture Charlie authority in the Hub",
)

require(
    "mode1a_guest_contribution_admission_status" in hub,
    "Mode 1A exposes admission status for Flower without re-signing",
)

flower_gate = function_source(flower, "require_mode1a_guest_admission")
require(
    "/mode1a/guest/contribution/admission/status" in flower_gate
    and "requests.get(" in flower_gate
    and 'requests.post(\n                f"{HUB_URL}/mode1a/guest/contribution/admission"' not in flower_gate,
    "Flower waits for an already verified Mode 1A admission",
)


# 4. Issuer application containers are hidden from the Hub network.
require(
    'resource "docker_network" "issuer_internal"' in main_tf
    and 'name = "issuer-internal"' in main_tf,
    "OpenTofu defines a private issuer-internal network",
)

for resource in ("issuer_hospitala", "issuer_hospitalb"):
    marker = f'resource "docker_container" "{resource}"'
    start = main_tf.index(marker)
    tail = main_tf[start:]
    next_resource = tail.find('\nresource "', 1)
    block = tail if next_resource == -1 else tail[:next_resource]
    require(
        "docker_network.issuer_internal.name" in block
        and "docker_network.fc.name" not in block,
        f"{resource} is not directly attached to fc",
    )

require(
    "ISSUER_A_URL=https://issuer-hospitala.local:8443" in main_tf
    and "ISSUER_B_URL=https://issuer-hospitalb.local:8443" in main_tf,
    "Hub reaches issuers through the mTLS issuer proxy",
)
