#!/usr/bin/env python3

import base64
import hashlib
import json
import os
import signal
import time
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


IDENTITY_DIR = Path(
    os.getenv("HAL_IDENTITY_DIR", "/var/lib/hal/identity")
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


def main() -> None:
    private_key = load_or_create_private_key()
    write_public_identity(private_key)

    print(
        f"Hal identity ready jkt={JKT_PATH.read_text().strip()}",
        flush=True,
    )
    print(
        "Hal has no operational federation authority at Gate 5A",
        flush=True,
    )

    running = True

    def stop(_signum, _frame):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    while running:
        time.sleep(60)


if __name__ == "__main__":
    main()
