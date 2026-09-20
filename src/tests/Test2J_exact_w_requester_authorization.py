#!/usr/bin/env python3
"""2D2 red/green gate for exact-W requester authorization.

The derivative path must be two-stage. W is created and content-addressed
before the human requester authorizes consumption. The browser proof must bind
the exact governed_value_id that Gatekeeper verifies and that the Hub releases.
"""

from __future__ import annotations

import pathlib
import re
import unittest


HERE = pathlib.Path(__file__).resolve()
SRC = HERE.parents[1]

APP = SRC / "vfp-core" / "frontend" / "src" / "App.jsx"
HOLDER_CRYPTO = SRC / "vfp-core" / "frontend" / "src" / "holderCrypto.js"
HUB = SRC / "vfp-core" / "hub" / "hub.py"
GATEKEEPER = SRC / "vfp-governance" / "gatekeeper" / "app.py"


def read(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def extract_braced_function(source: str, marker: str) -> str:
    start = source.find(marker)
    if start < 0:
        raise AssertionError(f"missing function marker: {marker}")

    signature_end = source.find(") {", start)
    if signature_end < 0:
        raise AssertionError(f"missing function body: {marker}")

    brace = signature_end + 2

    if brace < 0:
        raise AssertionError(f"missing function body: {marker}")

    depth = 0
    quote = None
    escaped = False

    for index in range(brace, len(source)):
        ch = source[index]

        if quote is not None:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == quote:
                quote = None
            continue

        if ch in {"'", '"', "`"}:
            quote = ch
            continue

        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]

    raise AssertionError(f"unterminated function: {marker}")


def extract_python_def(source: str, name: str) -> str:
    pattern = re.compile(
        rf"^(?:async\s+)?def {re.escape(name)}\b",
        re.MULTILINE,
    )
    match = pattern.search(source)
    if match is None:
        raise AssertionError(f"missing Python function: {name}")

    start = match.start()
    remainder = source[match.end():]
    next_match = re.search(
        r"^(?:async\s+def|def|@app\.)\b",
        remainder,
        re.MULTILINE,
    )
    if next_match is None:
        return source[start:]

    return source[start:match.end() + next_match.start()]


def endpoint_block(source: str, route: str) -> str:
    marker = f'@app.post("{route}")'
    start = source.find(marker)
    if start < 0:
        raise AssertionError(f"missing endpoint: {route}")

    remainder = source[start + len(marker):]
    next_endpoint = re.search(r"^@app\.", remainder, re.MULTILINE)
    if next_endpoint is None:
        return source[start:]

    return source[start:start + len(marker) + next_endpoint.start()]


class ExactWRequesterAuthorizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.app = read(APP)
        cls.crypto = read(HOLDER_CRYPTO)
        cls.hub = read(HUB)
        cls.gatekeeper = read(GATEKEEPER)

    def test_01_browser_dpop_can_bind_governed_value_id(self) -> None:
        signer = extract_braced_function(
            self.crypto,
            "export async function signHolderDpop",
        )

        self.assertIn("governedValueId", signer)
        self.assertIn("governed_value_id", signer)
        self.assertRegex(
            signer,
            r"governed_value_id\s*:\s*governedValueId",
        )

    def test_02_gatekeeper_requires_signed_exact_w_binding(self) -> None:
        probe = extract_python_def(
            self.gatekeeper,
            "_probe_impl",
        )

        self.assertIn("governed_value_id", probe)
        self.assertIn("dpop_governed_value_id_missing", probe)
        self.assertIn("dpop_governed_value_id_mismatch", probe)
        self.assertRegex(
            probe,
            r'body\.action\s*==\s*"consume_derivative"',
        )

    def test_03_mode1b_source_request_accepts_holder_evidence(self) -> None:
        request = endpoint_block(
            self.hub,
            "/mode1b/agent/request",
        )

        for symbol in [
            'Header(None, alias="Authorization")',
            'Header(None, alias="DPoP")',
            'Header(None, alias="X-DPoP-Nonce")',
            "jti=req.jti",
            "authorization=authorization",
            "dpop=dpop_header",
            "dpop_nonce=dpop_nonce",
        ]:
            self.assertIn(symbol, request)

        self.assertNotIn(
            "runtime_credential(req.requester",
            request,
        )
        self.assertNotRegex(
            request,
            r"admit_principal_operation\s*\(\s*principal=req\.requester",
        )

    def test_04_derivative_creation_stops_pending_before_release(self) -> None:
        request = endpoint_block(
            self.hub,
            "/mode1b/agent/request",
        )

        self.assertIn("PENDING_CONSUMER_AUTHORIZATION", request)
        self.assertIn("pending_id", request)
        self.assertIn("governed_value_id", request)
        self.assertIn("released", request)

        pending_position = request.find(
            "PENDING_CONSUMER_AUTHORIZATION"
        )
        release_call = request.find(
            'action="consume_derivative"'
        )

        self.assertGreaterEqual(pending_position, 0)
        self.assertTrue(
            release_call < 0 or pending_position < release_call,
            "consume_derivative is still performed before pending state",
        )

        # The first response may expose the content address and safe metadata,
        # but must not release W itself.
        pending_tail = request[pending_position:]
        first_return_end = pending_tail.find("\n        }")
        if first_return_end >= 0:
            pending_return = pending_tail[:first_return_end]
            self.assertNotIn('"prediction": governed_value', pending_return)
            self.assertNotIn('"derivative_image"', pending_return)

    def test_05_hub_has_separate_consume_endpoint(self) -> None:
        consume = endpoint_block(
            self.hub,
            "/mode1b/agent/consume",
        )

        for symbol in [
            "pending_id",
            'Header(None, alias="Authorization")',
            'Header(None, alias="DPoP")',
            'Header(None, alias="X-DPoP-Nonce")',
            'action="consume_derivative"',
            "governed_value_id=",
            "governed_value=",
            "authorization=authorization",
            "dpop=dpop_header",
            "dpop_nonce=dpop_nonce",
        ]:
            self.assertIn(symbol, consume)

        self.assertNotIn("sign_principal_dpop(", consume)
        self.assertNotIn("runtime_credential(", consume)
        self.assertNotIn("admit_principal_operation(", consume)

    def test_06_consume_releases_only_verified_same_w(self) -> None:
        consume = endpoint_block(
            self.hub,
            "/mode1b/agent/consume",
        )

        self.assertIn(
            'governed_value_binding_result") != "verified"',
            consume,
        )
        self.assertIn(
            'release_admission.get("governed_value_id")',
            consume,
        )
        self.assertIn(
            "governed_value_content_id(governed_value)",
            consume,
        )
        self.assertIn(
            '"prediction": governed_value',
            consume,
        )
        self.assertIn(
            '"released": True',
            consume,
        )

    def test_07_pending_state_is_single_use_and_requester_bound(self) -> None:
        consume = endpoint_block(
            self.hub,
            "/mode1b/agent/consume",
        )

        for symbol in [
            "pending_id",
            "requester",
            "envelope_id",
            "governed_value_id",
            "PENDING_CONSUMER_AUTHORIZATION",
            "RELEASED",
        ]:
            self.assertIn(symbol, consume)

        self.assertTrue(
            "pop(" in consume or '["state"] = "RELEASED"' in consume,
            "pending authorization is not consumed or terminally marked",
        )

    def test_08_frontend_uses_two_distinct_human_signatures(self) -> None:
        run = extract_braced_function(
            self.app,
            "async function runUserInference",
        )
        self.assertIn("/mode1b/agent/request", run)
        self.assertIn("signHolderDpop", run)
        self.assertIn("Authorization", run)
        self.assertIn("DPoP", run)

        self.assertIn(
            "async function authorizePendingDerivative",
            self.app,
        )
        authorize = extract_braced_function(
            self.app,
            "async function authorizePendingDerivative",
        )

        for symbol in [
            "/mode1b/agent/consume",
            "getHolderCredential",
            "signHolderDpop",
            "governedValueId",
            "Authorization",
            "DPoP",
            "X-DPoP-Nonce",
        ]:
            self.assertIn(symbol, authorize)

    def test_09_frontend_requires_explicit_pending_authorization_action(self) -> None:
        self.assertIn("PENDING_CONSUMER_AUTHORIZATION", self.app)
        self.assertIn("authorizePendingDerivative", self.app)
        self.assertRegex(
            self.app,
            r"AUTHORIZE(?:\s+EXACT)?\s+W",
        )

    def test_10_no_human_runtime_credential_dependency_remains_in_mode1b(self) -> None:
        request = endpoint_block(
            self.hub,
            "/mode1b/agent/request",
        )
        consume = endpoint_block(
            self.hub,
            "/mode1b/agent/consume",
        )

        combined = request + "\n" + consume

        self.assertNotIn(
            "runtime_credential(req.requester",
            combined,
        )
        self.assertNotRegex(
            combined,
            r"admit_principal_operation\s*\(\s*principal=req\.requester",
        )
        self.assertNotIn(
            'holder_runtime_credentials.get(',
            consume,
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
