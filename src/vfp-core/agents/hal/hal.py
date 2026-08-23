#!/usr/bin/env python3

import base64
import hashlib
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


IDENTITY_DIR = Path(
    os.getenv("HAL_IDENTITY_DIR", "/var/lib/hal/identity")
)
PORT = int(os.getenv("HAL_PORT", "8088"))
DPOP_HTU = os.getenv(
    "DPOP_HTU",
    "https://verifier.local/admission/check",
)

PRIVATE_KEY_PATH = IDENTITY_DIR / "holder.key"
PUBLIC_JWK_PATH = IDENTITY_DIR / "holder.jwk"
JKT_PATH = IDENTITY_DIR / "holder.jkt"


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def load_or_create_private_key() -> Ed25519PrivateKey:
    IDENTITY_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(IDENTITY_DIR, 0o700)

    if PRIVATE_KEY_PATH.exists():
        private_key = serialization.load_pem_private_key(
            PRIVATE_KEY_PATH.read_bytes(),
            password=None,
        )

        if not isinstance(private_key, Ed25519PrivateKey):
            raise RuntimeError("holder.key is not an Ed25519 private key")

        os.chmod(PRIVATE_KEY_PATH, 0o600)
        return private_key

    private_key = Ed25519PrivateKey.generate()

    pem = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )

    fd = os.open(
        PRIVATE_KEY_PATH,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        0o600,
    )

    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(pem)
    except Exception:
        PRIVATE_KEY_PATH.unlink(missing_ok=True)
        raise

    return private_key


def write_public_identity(private_key: Ed25519PrivateKey) -> None:
    public_raw = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )

    jwk = {
        "crv": "Ed25519",
        "kty": "OKP",
        "x": b64url(public_raw),
    }

    canonical = json.dumps(
        jwk,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")

    jkt = b64url(hashlib.sha256(canonical).digest())

    PUBLIC_JWK_PATH.write_text(
        json.dumps(jwk, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    JKT_PATH.write_text(jkt + "\n", encoding="utf-8")

    os.chmod(PUBLIC_JWK_PATH, 0o644)
    os.chmod(JKT_PATH, 0o644)


def encode_json(value: dict) -> str:
    return b64url(
        json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    )


def sign_dpop(private_key: Ed25519PrivateKey, payload: dict) -> str:
    if payload.get("sub") != "Hal":
        raise ValueError("invalid_subject")
    if payload.get("htu") != DPOP_HTU:
        raise ValueError("invalid_htu")
    if payload.get("htm") != "POST":
        raise ValueError("invalid_htm")

    jti = str(payload.get("jti") or "").strip()
    nonce = str(payload.get("nonce") or "").strip()
    envelope_id = str(payload.get("envelope_id") or "").strip()
    if not jti or not nonce or not envelope_id:
        raise ValueError("missing_dpop_binding")

    jwk = json.loads(PUBLIC_JWK_PATH.read_text(encoding="utf-8"))
    header = encode_json({
        "typ": "dpop+jwt",
        "alg": "EdDSA",
        "jwk": jwk,
    })
    claims = encode_json({
        "htu": DPOP_HTU,
        "htm": "POST",
        "iat": int(time.time()),
        "jti": jti,
        "nonce": nonce,
        "envelope_id": envelope_id,
    })
    signing_input = f"{header}.{claims}".encode("ascii")
    signature = b64url(private_key.sign(signing_input))
    return f"{header}.{claims}.{signature}"


def make_handler(private_key: Ed25519PrivateKey):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, _format, *_args):
            return

        def send_json(self, status: int, payload: dict) -> None:
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/health":
                self.send_json(200, {"status": "ok", "principal": "Hal"})
                return
            if self.path == "/identity":
                self.send_json(200, {
                    "principal": "Hal",
                    "jwk": json.loads(PUBLIC_JWK_PATH.read_text(encoding="utf-8")),
                    "jkt": JKT_PATH.read_text(encoding="utf-8").strip(),
                })
                return
            self.send_json(404, {"detail": "not_found"})

        def do_POST(self):
            if self.path != "/dpop/sign":
                self.send_json(404, {"detail": "not_found"})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                payload = json.loads(self.rfile.read(length) or b"{}")
                dpop = sign_dpop(private_key, payload)
            except (ValueError, json.JSONDecodeError) as exc:
                self.send_json(400, {"detail": str(exc)})
                return
            self.send_json(200, {
                "dpop": dpop,
                "jkt": JKT_PATH.read_text(encoding="utf-8").strip(),
            })

    return Handler


def main() -> None:
    private_key = load_or_create_private_key()
    write_public_identity(private_key)

    print(
        f"Hal identity ready jkt={JKT_PATH.read_text().strip()}",
        flush=True,
    )
    print(
        f"Hal holder signer ready on agent-edge port {PORT}",
        flush=True,
    )

    server = ThreadingHTTPServer(("0.0.0.0", PORT), make_handler(private_key))
    server.serve_forever(poll_interval=0.5)


if __name__ == "__main__":
    main()
