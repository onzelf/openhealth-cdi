#!/usr/bin/env python3
"""Verify a signed FCaC JSON artifact using only its pinned public key."""

from __future__ import annotations

import argparse
import base64
import json
import subprocess
import tempfile
from pathlib import Path
from typing import Any


def b64u_decode(value: str) -> bytes:
    padding = "=" * ((4 - len(value) % 4) % 4)
    return base64.urlsafe_b64decode(value + padding)


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--public-key", required=True)
    parser.add_argument("--artifact", required=True)
    parser.add_argument("--expected-type")
    parser.add_argument("--expected-kid")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    public_key = Path(args.public_key)
    artifact_path = Path(args.artifact)

    artifact = json.loads(artifact_path.read_text(encoding="utf-8"))
    if not isinstance(artifact, dict):
        raise SystemExit("artifact_not_object")

    evidence = artifact.get("evidence")
    if not isinstance(evidence, dict):
        raise SystemExit("evidence_missing")
    if evidence.get("alg") != "Ed25519":
        raise SystemExit("evidence_alg_invalid")
    if not evidence.get("kid"):
        raise SystemExit("evidence_kid_missing")
    if not evidence.get("signature"):
        raise SystemExit("evidence_signature_missing")

    artifact_type = artifact.get("artifact_type")
    if args.expected_type and artifact_type != args.expected_type:
        raise SystemExit(
            f"artifact_type_mismatch:{artifact_type}:{args.expected_type}"
        )
    if args.expected_kid and evidence.get("kid") != args.expected_kid:
        raise SystemExit(
            f"evidence_kid_mismatch:{evidence.get('kid')}:{args.expected_kid}"
        )

    unsigned = dict(artifact)
    unsigned.pop("evidence", None)

    with tempfile.TemporaryDirectory() as temp_dir:
        payload_path = Path(temp_dir) / "payload.json"
        signature_path = Path(temp_dir) / "signature.bin"
        payload_path.write_bytes(canonical_json(unsigned))
        signature_path.write_bytes(b64u_decode(str(evidence["signature"])))

        result = subprocess.run(
            [
                "openssl",
                "pkeyutl",
                "-verify",
                "-pubin",
                "-inkey",
                str(public_key),
                "-rawin",
                "-in",
                str(payload_path),
                "-sigfile",
                str(signature_path),
            ],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise SystemExit(f"signature_invalid:{detail}")

    identifier = (
        artifact.get("decision_id")
        or artifact.get("envelope_id")
        or artifact.get("bind_id")
        or "unknown"
    )
    print(
        json.dumps(
            {
                "ok": True,
                "artifact_type": artifact_type,
                "id": identifier,
                "kid": evidence["kid"],
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
