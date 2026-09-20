#!/usr/bin/env python3
"""Behavioral adversarial tests for exact-W DPoP binding at Gatekeeper."""

from __future__ import annotations

import asyncio
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

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec, ed25519
from nacl import signing
from starlette.requests import Request


def b64u(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def canonical(obj: dict) -> bytes:
    return json.dumps(
        obj,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")


def value_id(value: dict) -> str:
    unsigned = dict(value)
    unsigned.pop("value_id", None)
    return "sha256:" + hashlib.sha256(canonical(unsigned)).hexdigest()


def make_w(
    *,
    tissue: str = "mucus",
    image: bytes = b"exact-w-image",
) -> dict:
    image_sha = hashlib.sha256(image).hexdigest()
    w = {
        "resource": "pathmnist-derived-representation",
        "requested_tissue": tissue,
        "actual_label": 1,
        "prediction_label": 1,
        "prediction_tissue": tissue,
        "topk": [{"label": 1, "probability": 0.9}],
        "derivative_representation":
            "blurred_image_with_qualitative_accuracy",
        "derivative_sha256": image_sha,
        "derivative_image": {
            "mime_type": "image/png",
            "image_b64": base64.b64encode(image).decode("ascii"),
            "width": 8,
            "height": 8,
        },
    }
    w["value_id"] = value_id(w)
    return w


def request() -> Request:
    return Request({
        "type": "http",
        "http_version": "1.1",
        "method": "POST",
        "scheme": "https",
        "path": "/admission/check",
        "raw_path": b"/admission/check",
        "query_string": b"",
        "headers": [(b"host", b"verifier.local")],
        "client": ("127.0.0.1", 12345),
        "server": ("verifier.local", 443),
    })


class FakeRedis:
    def __init__(self) -> None:
        self.keys: set[str] = set()

    async def set(
        self,
        key: str,
        value: str,
        *,
        ex: int,
        nx: bool,
    ):
        if nx and key in self.keys:
            return None
        self.keys.add(key)
        return True


class ExactWBindingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.tmp = tempfile.TemporaryDirectory()
        root = pathlib.Path(cls.tmp.name)
        state = root / "state"
        certs = root / "certs"
        state.mkdir()
        certs.mkdir()

        policy = {
            "version": "test-exact-w",
            "constitutive": {
                "participants": [
                    {"org": "org://HospitalA"},
                    {"org": "org://HospitalB"},
                ],
                "quorum": {"k": 2, "n": 2},
            },
            "ops": {
                "consume": {
                    "resource": "pathmnist-derived-representation",
                    "action": "consume_derivative",
                    "purpose": "approved_derivative_consumption",
                    "scope": {
                        "pathology_labels": ["mucus"],
                    },
                },
            },
            "cap_profiles": {
                "TEST_CONSUMER": {
                    "cap": ["consume"],
                },
            },
            "meta": {
                "policy_id": "test-policy",
                "manifest_id": "test-manifest",
            },
            "caveats": {
                "audience": "svc:fl-gateway:eu",
                "reserved_pathology_labels": [],
            },
        }
        (state / "policy.json").write_text(
            json.dumps(policy),
            encoding="utf-8",
        )

        org_key = ec.generate_private_key(ec.SECP256R1())
        org_pem = org_key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
        org_path = certs / "HospitalA-admin.key"
        org_path.write_bytes(org_pem)

        evidence_key = ed25519.Ed25519PrivateKey.generate()
        evidence_private = evidence_key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
        evidence_public = evidence_key.public_key().public_bytes(
            serialization.Encoding.PEM,
            serialization.PublicFormat.SubjectPublicKeyInfo,
        )
        evidence_private_path = certs / "fcac-evidence.key"
        evidence_public_path = certs / "fcac-evidence.pub"
        evidence_private_path.write_bytes(evidence_private)
        evidence_public_path.write_bytes(evidence_public)

        os.environ["FCAC_STATE_DIR"] = str(state)
        os.environ["FCAC_CERTS_DIR"] = str(certs)
        os.environ["ORG_KEY_FILE"] = str(org_path)
        os.environ["EVIDENCE_PRIVATE_KEY_FILE"] = str(
            evidence_private_path
        )
        os.environ["EVIDENCE_PUBLIC_KEY_FILE"] = str(
            evidence_public_path
        )
        os.environ["ISS"] = "https://issuer.test"
        os.environ["AUD"] = "svc:fl-gateway:eu"
        os.environ["REQUIRE_MTLS_HEADERS"] = "false"
        os.environ["DPOP_MAX_AGE_SECONDS"] = "60"
        os.environ["DPOP_CLOCK_SKEW_SECONDS"] = "5"
        os.environ["BENCH"] = "0"

        sys.path.insert(0, "/app")
        cls.gk = importlib.import_module("app")
        cls.redis = FakeRedis()

        async def fake_get_redis():
            return cls.redis

        cls.gk.get_redis = fake_get_redis
        cls.org_key = org_key

        cls.audrey = signing.SigningKey.generate()
        cls.mallory = signing.SigningKey.generate()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.tmp.cleanup()

    def setUp(self) -> None:
        self.redis.keys.clear()

    def ect(
        self,
        holder: signing.SigningKey,
        *,
        subject: str = "Audrey",
        envelope_id: str = "E1",
    ) -> str:
        pub = b64u(holder.verify_key.encode())
        now = int(time.time())
        payload = {
            "iss": self.gk.ISS,
            "aud": self.gk._aud,
            "iat": now,
            "nbf": now - 5,
            "exp": now + 300,
            "sub": subject,
            "actor_type": "human",
            "org_iss": "org://HospitalA",
            "policy": {
                "policy_id": "test-policy",
                "manifest_id": "test-manifest",
                "policy_hash": self.gk._policy_hash,
            },
            "envelope_id": envelope_id,
            "cnf": {
                "jkt": self.gk.rfc7638_thumbprint_okp_ed25519(pub),
            },
            "cap_profiles": ["TEST_CONSUMER"],
            "cap": [{
                "resource": "pathmnist-derived-representation",
                "action": "consume_derivative",
                "purpose": "approved_derivative_consumption",
                "scope": {
                    "pathology_labels": ["mucus"],
                },
            }],
        }
        return jwt.encode(
            payload,
            self.org_key,
            algorithm="ES256",
            headers={"alg": "ES256", "kid": "test-org"},
        )

    def dpop(
        self,
        holder: signing.SigningKey,
        *,
        envelope_id: str = "E1",
        governed_value_id: str | None,
        jti: str,
        nonce: str,
    ) -> str:
        pub = b64u(holder.verify_key.encode())
        header = {
            "typ": "dpop+jwt",
            "alg": "EdDSA",
            "jwk": {
                "kty": "OKP",
                "crv": "Ed25519",
                "x": pub,
            },
        }
        claims = {
            "htu": "https://verifier.local/admission/check",
            "htm": "POST",
            "iat": int(time.time()),
            "jti": jti,
            "nonce": nonce,
            "envelope_id": envelope_id,
        }
        if governed_value_id is not None:
            claims["governed_value_id"] = governed_value_id

        encoded_header = b64u(canonical(header))
        encoded_claims = b64u(canonical(claims))
        signing_input = (
            f"{encoded_header}.{encoded_claims}".encode("ascii")
        )
        signature = holder.sign(signing_input).signature
        return (
            f"{encoded_header}.{encoded_claims}.{b64u(signature)}"
        )

    def probe_body(
        self,
        w: dict,
        *,
        jti: str,
        governed_value_id: str | None = None,
        include_value: bool = True,
    ):
        return self.gk.ProbeReq(
            envelope_id="E1",
            run_id="run-test",
            resource="pathmnist-derived-representation",
            action="consume_derivative",
            purpose="approved_derivative_consumption",
            requested_tissues=["mucus"],
            derivative_representation=
                "blurred_image_with_qualitative_accuracy",
            governed_value_id=(
                w["value_id"]
                if governed_value_id is None
                else governed_value_id
            ),
            governed_value=w if include_value else None,
            jti=jti,
        )

    def run_probe(
        self,
        *,
        w: dict,
        holder: signing.SigningKey | None = None,
        ect_holder: signing.SigningKey | None = None,
        proof_value_id: str | None,
        body_value_id: str | None = None,
        jti: str,
        nonce: str,
        include_value: bool = True,
        proof_envelope_id: str = "E1",
    ):
        holder = holder or self.audrey
        ect_holder = ect_holder or self.audrey
        body = self.probe_body(
            w,
            jti=jti,
            governed_value_id=body_value_id,
            include_value=include_value,
        )
        return asyncio.run(
            self.gk._probe_impl(
                request(),
                body,
                "ECT " + self.ect(ect_holder),
                self.dpop(
                    holder,
                    envelope_id=proof_envelope_id,
                    governed_value_id=proof_value_id,
                    jti=jti,
                    nonce=nonce,
                ),
                nonce,
            )
        )

    def test_01_valid_exact_w_allows(self) -> None:
        w = make_w()
        result = self.run_probe(
            w=w,
            proof_value_id=w["value_id"],
            jti="jti-valid",
            nonce="nonce-valid",
        )
        self.assertTrue(result.allow)
        self.assertEqual(result.governed_value_id, w["value_id"])
        self.assertEqual(
            result.governed_value_binding_result,
            "verified",
        )

    def test_02_missing_w_id_in_proof_denied(self) -> None:
        w = make_w()
        result = self.run_probe(
            w=w,
            proof_value_id=None,
            jti="jti-missing-proof-w",
            nonce="nonce-missing-proof-w",
        )
        self.assertFalse(result.allow)
        self.assertEqual(
            result.reason,
            "dpop_governed_value_id_missing",
        )

    def test_03_proof_w1_body_w2_denied(self) -> None:
        w1 = make_w(image=b"W1")
        w2 = make_w(image=b"W2")
        result = self.run_probe(
            w=w2,
            proof_value_id=w1["value_id"],
            jti="jti-w1-w2",
            nonce="nonce-w1-w2",
        )
        self.assertFalse(result.allow)
        self.assertEqual(
            result.reason,
            "dpop_governed_value_id_mismatch",
        )

    def test_04_tamper_w_after_proof_denied(self) -> None:
        w = make_w()
        signed_value_id = w["value_id"]
        tampered = json.loads(json.dumps(w))
        tampered["prediction_label"] = 8

        result = self.run_probe(
            w=tampered,
            proof_value_id=signed_value_id,
            body_value_id=signed_value_id,
            jti="jti-tampered-w",
            nonce="nonce-tampered-w",
        )
        self.assertFalse(result.allow)
        self.assertEqual(
            result.reason,
            "governed_value_id_mismatch",
        )
        self.assertEqual(
            result.governed_value_binding_result,
            "failed",
        )

    def test_05_missing_w_preimage_denied(self) -> None:
        w = make_w()
        result = self.run_probe(
            w=w,
            proof_value_id=w["value_id"],
            jti="jti-no-preimage",
            nonce="nonce-no-preimage",
            include_value=False,
        )
        self.assertFalse(result.allow)
        self.assertEqual(result.reason, "governed_value_required")

    def test_06_wrong_holder_key_denied(self) -> None:
        w = make_w()
        result = self.run_probe(
            w=w,
            holder=self.mallory,
            ect_holder=self.audrey,
            proof_value_id=w["value_id"],
            jti="jti-wrong-holder",
            nonce="nonce-wrong-holder",
        )
        self.assertFalse(result.allow)
        self.assertEqual(result.reason, "dpop_binding_mismatch")

    def test_07_replay_denied(self) -> None:
        w = make_w()
        kwargs = {
            "w": w,
            "proof_value_id": w["value_id"],
            "jti": "jti-replay",
            "nonce": "nonce-replay",
        }
        first = self.run_probe(**kwargs)
        second = self.run_probe(**kwargs)
        self.assertTrue(first.allow)
        self.assertFalse(second.allow)
        self.assertEqual(second.reason, "dpop_replay")

    def test_08_wrong_envelope_in_proof_denied(self) -> None:
        w = make_w()
        result = self.run_probe(
            w=w,
            proof_value_id=w["value_id"],
            proof_envelope_id="E2",
            jti="jti-wrong-envelope",
            nonce="nonce-wrong-envelope",
        )
        self.assertFalse(result.allow)
        self.assertEqual(result.reason, "dpop_envelope_mismatch")

    def test_09_malformed_body_w_id_denied(self) -> None:
        w = make_w()
        result = self.run_probe(
            w=w,
            proof_value_id="not-a-content-address",
            body_value_id="not-a-content-address",
            jti="jti-malformed-id",
            nonce="nonce-malformed-id",
        )
        self.assertFalse(result.allow)
        self.assertEqual(result.reason, "governed_value_id_required")

    def test_10_derivative_bytes_tamper_denied(self) -> None:
        w = make_w()
        signed_value_id = w["value_id"]
        tampered = json.loads(json.dumps(w))
        tampered["derivative_image"]["image_b64"] = (
            base64.b64encode(b"other-image").decode("ascii")
        )

        result = self.run_probe(
            w=tampered,
            proof_value_id=signed_value_id,
            body_value_id=signed_value_id,
            jti="jti-image-tamper",
            nonce="nonce-image-tamper",
        )
        self.assertFalse(result.allow)
        self.assertEqual(
            result.reason,
            "governed_value_id_mismatch",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
