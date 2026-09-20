#!/usr/bin/env python3
"""2D1 red/green gate for browser-held human credentials.

This is intentionally a source-level architecture test. 2C is not a deployable
application milestone because the old human execution paths still expect Hub
credential custody. 2D1 must move those paths to holder-supplied evidence
before the stack is rebuilt.
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


def read(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def extract_braced_function(source: str, marker: str) -> str:
    start = source.find(marker)
    if start < 0:
        raise AssertionError(f"missing function marker: {marker}")

    brace = source.find("{", start)
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
    pattern = re.compile(rf"^def {re.escape(name)}\b", re.MULTILINE)
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


class BrowserHolderCustodyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.app = read(APP)
        cls.crypto = read(HOLDER_CRYPTO)
        cls.hub = read(HUB)

    def test_01_browser_has_holder_credential_store(self) -> None:
        self.assertIn(
            "export async function getHolderCredential",
            self.crypto,
        )
        self.assertIn(
            "export async function putHolderCredential",
            self.crypto,
        )
        put = extract_braced_function(
            self.crypto,
            "export async function putHolderCredential",
        )
        self.assertIn("credentials", put)
        self.assertIn("ect", put)
        self.assertIn("expires_at", put)
        self.assertIn('withStore("readwrite"', put)

    def test_02_browser_mint_uses_holder_proof_and_keeps_human_ect(self) -> None:
        mint = extract_braced_function(
            self.app,
            "async function mintHolderEct",
        )

        for symbol in [
            "getHolderIdentity",
            "createHolderIdentity",
            "holderEnrollmentRecord",
            "signHolderDpop",
            "MINT_PROOF_HTU",
            "holder_dpop",
            "putHolderCredential",
        ]:
            self.assertIn(symbol, mint)

        self.assertRegex(
            mint,
            r"putHolderCredential\s*\(\s*principal\s*,",
        )
        self.assertIn("result.ect", mint)
        self.assertIn("result.expires_at", mint)

    def test_03_browser_inference_supplies_ect_and_fresh_dpop(self) -> None:
        run = extract_braced_function(
            self.app,
            "async function runUserInference",
        )

        for symbol in [
            "getHolderCredential",
            "signHolderDpop",
            "DPOP_HTU",
            "Authorization",
            "DPoP",
            "X-DPoP-Nonce",
            "requestBody.jti",
        ]:
            self.assertIn(symbol, run)

        self.assertRegex(
            run,
            r"Authorization\s*:\s*`ECT \$\{credential\.ect\}`",
        )

    def test_04_hub_user_inference_accepts_holder_evidence(self) -> None:
        model = re.search(
            r"class UserInferenceRequest\(BaseModel\):(?P<body>.*?)(?=^class )",
            self.hub,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(model)
        self.assertRegex(model.group("body"), r"(?m)^\s+jti\s*:", msg="request has no JTI",)

        user = extract_python_def(self.hub, "user_inference")
        for symbol in [
            'Header(None, alias="Authorization")',
            'Header(None, alias="DPoP")',
            'Header(None, alias="X-DPoP-Nonce")',
            "authorization=authorization",
            "dpop=dpop_header",
            "dpop_nonce=dpop_nonce",
            "jti=req.jti",
        ]:
            self.assertIn(symbol, user)

    def test_05_hub_does_not_custody_or_sign_for_human_inference(self) -> None:
        user = extract_python_def(self.hub, "user_inference")

        self.assertNotIn("holder_runtime_credentials", user)
        self.assertNotIn("runtime_credential(", user)
        self.assertNotIn("sign_principal_dpop(", user)
        self.assertNotIn("credential['ect']", user)
        self.assertIn('principal_context.get("actor_type") != "human"', user)
        self.assertIn("presented_ect_subject_mismatch", user)

    def test_06_hub_runtime_credential_store_remains_agent_only(self) -> None:
        admin = extract_python_def(
            self.hub,
            "administration_mint_holder_ect",
        )

        store_index = admin.find("holder_runtime_credentials[")
        self.assertGreaterEqual(
            store_index,
            0,
            "administration mint no longer exposes the runtime store",
        )

        guard_index = admin.rfind(
            'if principal_context.get("actor_type") == "agent":',
            0,
            store_index,
        )
        self.assertGreaterEqual(
            guard_index,
            0,
            "runtime ECT storage is not guarded by actor_type == agent",
        )

        human_guard = admin.find("holder_mint_proof_required")
        self.assertGreaterEqual(
            human_guard,
            0,
            "human mint no longer requires holder proof",
        )
        self.assertLess(
            human_guard,
            store_index,
            "human proof requirement occurs after credential storage",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
