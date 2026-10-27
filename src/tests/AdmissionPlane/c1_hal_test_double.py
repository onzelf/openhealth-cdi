#!/usr/bin/env python3

import base64
import hashlib
import json
import secrets
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from cryptography.hazmat.primitives import serialization


IDENTITY = Path("/var/lib/hal/identity")
AUDIT = Path("/audit")
ACTION_FILE = AUDIT / "forced_action.txt"
DECIDE_FILE = AUDIT / "hal_decide_request.json"
ECT_STATE_FILE = IDENTITY / "holder_ect.json"
DPOP_HTU = "https://verifier.local/admission/check"

HAL_AUTHORITY_OPERATIONS = {
    (
        "pathmnist-colon-pathology",
        "bounded_inference",
        "bounded_model_inference",
    ),
    (
        "pathmnist-colon-pathology",
        "unbind",
        "policy_authorized_derivation",
    ),
}

PRIVATE_KEY = serialization.load_pem_private_key(
    (IDENTITY / "holder.key").read_bytes(),
    password=None,
)

JWK = json.loads(
    (IDENTITY / "holder.jwk").read_text(encoding="utf-8")
)

JKT = (IDENTITY / "holder.jkt").read_text(encoding="utf-8").strip()


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def encode_json(value: dict) -> str:
    return b64url(
        json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    )


def sign_dpop(payload: dict) -> str:
    header = encode_json(
        {
            "typ": "dpop+jwt",
            "alg": "EdDSA",
            "jwk": JWK,
        }
    )

    claims_payload = {
        "htu": str(payload.get("htu") or ""),
        "htm": str(payload.get("htm") or ""),
        "iat": int(time.time()),
        "jti": str(payload.get("jti") or ""),
        "nonce": str(payload.get("nonce") or ""),
        "envelope_id": str(payload.get("envelope_id") or ""),
    }

    request_hash = str(payload.get("request_hash") or "").strip()
    if request_hash:
        claims_payload["request_hash"] = request_hash

    claims = encode_json(claims_payload)

    signing_input = f"{header}.{claims}".encode("ascii")
    signature = b64url(PRIVATE_KEY.sign(signing_input))
    return f"{header}.{claims}.{signature}"


def decode_compact_claims(token: str) -> dict:
    parts = token.split(".")
    if len(parts) != 3:
        raise ValueError("not_compact_jws")
    encoded = parts[1] + "=" * (-len(parts[1]) % 4)
    value = json.loads(base64.urlsafe_b64decode(encoded).decode("utf-8"))
    if not isinstance(value, dict):
        raise ValueError("invalid_ect")
    return value


def load_cached_ect(envelope_id: str) -> str:
    if not ECT_STATE_FILE.is_file():
        raise ValueError("hal_cached_ect_missing")

    state = json.loads(ECT_STATE_FILE.read_text(encoding="utf-8"))
    ect = str(state.get("ect") or "").strip()
    claims = decode_compact_claims(ect)

    if str(claims.get("sub") or "") != "Hal":
        raise ValueError("hal_cached_ect_subject_mismatch")
    if str(claims.get("envelope_id") or "") != envelope_id:
        raise ValueError("hal_cached_ect_envelope_mismatch")
    if int(claims.get("exp") or 0) <= int(time.time()) + 5:
        raise ValueError("hal_cached_ect_expired")

    return ect


def governed_request_hash(value: dict) -> str:
    canonical = json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")
    return "sha256:" + hashlib.sha256(canonical).hexdigest()


def authority_presentation(payload: dict) -> dict:
    if str(payload.get("principal") or "").strip() != "Hal":
        raise ValueError("principal_mismatch")

    envelope_id = str(payload.get("envelope_id") or "").strip()
    run_id = str(payload.get("run_id") or "").strip()
    resource = str(payload.get("resource") or "").strip()
    action = str(payload.get("action") or "").strip()
    purpose = str(payload.get("purpose") or "").strip()
    requested_tissues = payload.get("requested_tissues")

    if not envelope_id or not run_id:
        raise ValueError("authority_context_required")
    if (resource, action, purpose) not in HAL_AUTHORITY_OPERATIONS:
        raise ValueError("authority_operation_not_supported")
    if (
        not isinstance(requested_tissues, list)
        or len(requested_tissues) != 1
        or not isinstance(requested_tissues[0], str)
        or not requested_tissues[0].strip()
    ):
        raise ValueError("authority_tissue_required")

    exact_request = {
        key: value
        for key, value in payload.items()
        if key != "principal"
    }

    ect = load_cached_ect(envelope_id)
    request_hash = governed_request_hash(exact_request)
    nonce = "c1-nonce-" + secrets.token_urlsafe(18)
    jti = "c1-jti-" + secrets.token_urlsafe(18)

    dpop = sign_dpop(
        {
            "htu": DPOP_HTU,
            "htm": "POST",
            "jti": jti,
            "nonce": nonce,
            "envelope_id": envelope_id,
            "request_hash": request_hash,
        }
    )

    return {
        "principal": "Hal",
        "envelope_id": envelope_id,
        "authorization": f"ECT {ect}",
        "dpop": dpop,
        "nonce": nonce,
        "jti": jti,
        "request_hash": request_hash,
        "request": exact_request,
    }


def forced_action() -> str:
    try:
        action = ACTION_FILE.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        action = "refuse"
    return action or "refuse"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        return

    def send_json(self, status: int, value: dict):
        raw = json.dumps(value).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def read_json(self):
        length = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(length) or b"{}")

    def do_GET(self):
        if self.path == "/health":
            self.send_json(
                200,
                {
                    "status": "ok",
                    "principal": "Hal",
                    "test_double": True,
                    "forced_action": forced_action(),
                },
            )
            return

        self.send_json(404, {"detail": "not_found"})

    def do_POST(self):
        try:
            payload = self.read_json()
        except Exception as exc:
            self.send_json(400, {"detail": str(exc)})
            return

        if self.path == "/decide":
            DECIDE_FILE.write_text(
                json.dumps(payload, indent=2, sort_keys=True),
                encoding="utf-8",
            )

            action = forced_action()
            self.send_json(
                200,
                {
                    "action": action,
                    "rationale": f"forced C1 audit output: {action}",
                    "model": "audit-test-double",
                    "fallback": False,
                },
            )
            return

        if self.path == "/authority/present":
            try:
                presentation = authority_presentation(payload)
            except Exception as exc:
                self.send_json(400, {"detail": str(exc)})
                return

            self.send_json(200, presentation)
            return

        self.send_json(404, {"detail": "not_found"})


server = ThreadingHTTPServer(("0.0.0.0", 8088), Handler)
server.serve_forever()
