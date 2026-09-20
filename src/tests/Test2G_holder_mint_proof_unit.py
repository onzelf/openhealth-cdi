#!/usr/bin/env python3
"""Source-level adversarial tests for holder-authenticated issuer minting."""

from __future__ import annotations

import base64
import hashlib
import importlib
import json
import os
import pathlib
import sys
import tempfile
import time
import unittest

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from pydantic import ValidationError


def b64u(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def canonical(obj: dict) -> bytes:
    return json.dumps(
        obj,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def public_jwk(private_key: Ed25519PrivateKey) -> dict:
    public_raw = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    return {
        "kty": "OKP",
        "crv": "Ed25519",
        "x": b64u(public_raw),
    }


def jkt(jwk: dict) -> str:
    digest = hashlib.sha256(
        canonical({
            "crv": jwk["crv"],
            "kty": jwk["kty"],
            "x": jwk["x"],
        })
    ).digest()
    return b64u(digest)


def member_for(private_key: Ed25519PrivateKey, subject: str) -> dict:
    jwk = public_jwk(private_key)
    return {
        "org_id": "org://HospitalA",
        "member_id": subject,
        "sub": subject,
        "pub_b64": jwk["x"],
        "jkt": jkt(jwk),
    }


def proof(
    private_key: Ed25519PrivateKey,
    *,
    envelope_id: str,
    htu: str = "urn:openhealth:issuer:mint",
    htm: str = "POST",
    iat: int | None = None,
    jti_value: str = "jti-test",
    nonce: str = "nonce-test",
    tamper_signature: bool = False,
) -> str:
    header = {
        "typ": "dpop+jwt",
        "alg": "EdDSA",
        "jwk": public_jwk(private_key),
    }
    claims = {
        "htu": htu,
        "htm": htm,
        "iat": int(time.time()) if iat is None else iat,
        "jti": jti_value,
        "nonce": nonce,
        "envelope_id": envelope_id,
    }
    encoded_header = b64u(canonical(header))
    encoded_claims = b64u(canonical(claims))
    signing_input = f"{encoded_header}.{encoded_claims}".encode("ascii")
    signature = bytearray(private_key.sign(signing_input))
    if tamper_signature:
        signature[0] ^= 0x01
    return f"{encoded_header}.{encoded_claims}.{b64u(bytes(signature))}"


class HolderMintProofTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.tmp = tempfile.TemporaryDirectory()
        root = pathlib.Path(cls.tmp.name)

        cap_profiles = root / "cap_profiles.json"
        entitlements = root / "entitlements.json"
        registry = root / "registry"
        registry.mkdir()

        cap_profiles.write_text(
            json.dumps({
                "org://HospitalA": {
                    "TEST_READER": "capset:test_reader",
                }
            }),
            encoding="utf-8",
        )
        entitlements.write_text(
            json.dumps({
                "org": "org://HospitalA",
                "members": {
                    "Audrey": "TEST_READER",
                    "Charlie": "TEST_READER",
                    "Hal": "TEST_READER",
                },
                "actor_types": {
                    "Hal": "agent",
                },
            }),
            encoding="utf-8",
        )

        os.environ["ORG"] = "org://HospitalA"
        os.environ["REGISTRY_DIR"] = str(registry)
        os.environ["CAP_PROFILE_PATH"] = str(cap_profiles)
        os.environ["MEMBER_ENTITLEMENTS_PATH"] = str(entitlements)
        os.environ["MINT_PROOF_HTU"] = "urn:openhealth:issuer:mint"
        os.environ["MINT_PROOF_MAX_AGE_SECONDS"] = "120"
        os.environ["MINT_PROOF_CLOCK_SKEW_SECONDS"] = "30"

        sys.path.insert(0, "/app")
        cls.issuer = importlib.import_module("issuer")

        cls.audrey_key = Ed25519PrivateKey.generate()
        cls.charlie_key = Ed25519PrivateKey.generate()
        cls.hal_key = Ed25519PrivateKey.generate()

        cls.audrey = member_for(cls.audrey_key, "Audrey")
        cls.charlie = member_for(cls.charlie_key, "Charlie")
        cls.hal = member_for(cls.hal_key, "Hal")

    @classmethod
    def tearDownClass(cls) -> None:
        cls.tmp.cleanup()

    def assert_denied(
        self,
        expected_status: int,
        expected_detail: str,
        *,
        compact: str,
        member: dict,
        envelope_id: str = "E1",
    ) -> None:
        with self.assertRaises(self.issuer.HTTPException) as ctx:
            self.issuer._verify_holder_mint_proof(
                compact,
                member,
                envelope_id,
            )
        self.assertEqual(ctx.exception.status_code, expected_status)
        self.assertEqual(ctx.exception.detail, expected_detail)

    def test_01_mint_model_requires_holder_proof(self) -> None:
        with self.assertRaises(ValidationError):
            self.issuer.MintReq(
                sub="Audrey",
                envelope_id="E1",
            )

    def test_02_valid_enrolled_holder_proof(self) -> None:
        self.issuer._verify_holder_mint_proof(
            proof(
                self.audrey_key,
                envelope_id="E1",
                jti_value="jti-valid",
                nonce="nonce-valid",
            ),
            self.audrey,
            "E1",
        )

    def test_03_wrong_holder_key(self) -> None:
        attacker = Ed25519PrivateKey.generate()
        self.assert_denied(
            401,
            "holder_mint_key_mismatch",
            compact=proof(
                attacker,
                envelope_id="E1",
                jti_value="jti-wrong-key",
                nonce="nonce-wrong-key",
            ),
            member=self.audrey,
        )

    def test_04_wrong_envelope(self) -> None:
        self.assert_denied(
            401,
            "holder_mint_envelope_mismatch",
            compact=proof(
                self.audrey_key,
                envelope_id="E2",
                jti_value="jti-wrong-envelope",
                nonce="nonce-wrong-envelope",
            ),
            member=self.audrey,
        )

    def test_05_stale_proof(self) -> None:
        self.assert_denied(
            401,
            "holder_mint_proof_expired",
            compact=proof(
                self.audrey_key,
                envelope_id="E1",
                iat=int(time.time()) - 300,
                jti_value="jti-stale",
                nonce="nonce-stale",
            ),
            member=self.audrey,
        )

    def test_06_future_dated_proof(self) -> None:
        self.assert_denied(
            401,
            "holder_mint_proof_from_future",
            compact=proof(
                self.audrey_key,
                envelope_id="E1",
                iat=int(time.time()) + 300,
                jti_value="jti-future",
                nonce="nonce-future",
            ),
            member=self.audrey,
        )

    def test_07_wrong_htu(self) -> None:
        self.assert_denied(
            401,
            "holder_mint_htu_mismatch",
            compact=proof(
                self.audrey_key,
                envelope_id="E1",
                htu="https://verifier.local/admission/check",
                jti_value="jti-wrong-htu",
                nonce="nonce-wrong-htu",
            ),
            member=self.audrey,
        )

    def test_08_tampered_signature(self) -> None:
        self.assert_denied(
            401,
            "invalid_holder_mint_signature",
            compact=proof(
                self.audrey_key,
                envelope_id="E1",
                jti_value="jti-tampered",
                nonce="nonce-tampered",
                tamper_signature=True,
            ),
            member=self.audrey,
        )

    def test_09_subject_substitution(self) -> None:
        self.assert_denied(
            401,
            "holder_mint_key_mismatch",
            compact=proof(
                self.audrey_key,
                envelope_id="E1",
                jti_value="jti-audrey-for-charlie",
                nonce="nonce-audrey-for-charlie",
            ),
            member=self.charlie,
        )

    def test_10_replay(self) -> None:
        compact = proof(
            self.audrey_key,
            envelope_id="E1",
            jti_value="jti-replay",
            nonce="nonce-replay",
        )
        self.issuer._verify_holder_mint_proof(
            compact,
            self.audrey,
            "E1",
        )
        self.assert_denied(
            409,
            "mint_proof_replayed",
            compact=compact,
            member=self.audrey,
        )

    def test_11_agent_key_obeys_same_holder_binding(self) -> None:
        self.issuer._verify_holder_mint_proof(
            proof(
                self.hal_key,
                envelope_id="E1",
                jti_value="jti-hal",
                nonce="nonce-hal",
            ),
            self.hal,
            "E1",
        )

    def test_12_agent_proof_cannot_mint_for_human(self) -> None:
        self.assert_denied(
            401,
            "holder_mint_key_mismatch",
            compact=proof(
                self.hal_key,
                envelope_id="E1",
                jti_value="jti-hal-for-audrey",
                nonce="nonce-hal-for-audrey",
            ),
            member=self.audrey,
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
