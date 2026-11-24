#!/usr/bin/env python3
"""L1-B2: a new Flower execution key for one hospital, made with that hospital's own AWS credentials.

The private key is generated in memory and goes straight into the hospital's existing Secrets
Manager secret through the AWS CLI's standard input. It is never written to disk, printed or put
on a command line, so only the hospital's own account ever holds it. The public half is printed
and saved as JSON, ready to be registered with the hospital's issuer (Hospital C's with Hospital A's
issuer, as its sponsor).

  python3 make-execution-key.py --hospital a --profile <a-profile> --out-dir <folder> [--dry-run]

--dry-run makes a key and prints its public half but stores nothing (the key is discarded).
Needs: python3 with `cryptography`, the AWS CLI v2.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import pathlib
import subprocess
import sys

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import (
    Encoding,
    NoEncryption,
    PrivateFormat,
    PublicFormat,
)

# hospital -> (issuer organisation, member sub, secret name); as preflight_bootstrap.sh and
# bootstrap_members.sh register them, and as aws-l1b1/participant names the secrets.
HOSPITALS = {
    "a": ("org://HospitalA", "flower-execution", "openhealth-l1b-flower-execution-key-a"),
    "b": ("org://HospitalB", "flower-execution", "openhealth-l1b-flower-execution-key-b"),
    "c": ("org://HospitalA", "flower-execution-guest-HospitalC", "openhealth-l1b-flower-execution-key-c"),
}


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def jkt(pub_b64: str) -> str:
    """RFC 7638 thumbprint, exactly as src/tools/gen_member_keys.py computes it."""
    jwk = {"crv": "Ed25519", "kty": "OKP", "x": pub_b64}
    canonical = json.dumps(jwk, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return b64url(hashlib.sha256(canonical.encode("utf-8")).digest())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--hospital", required=True, choices=sorted(HOSPITALS))
    parser.add_argument("--profile", required=True, help="the AWS CLI profile of that hospital's account")
    parser.add_argument("--region", default="eu-west-2")
    parser.add_argument("--out-dir", default=".", help="where the public half is saved")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    org_id, sub, secret_id = HOSPITALS[args.hospital]
    out = pathlib.Path(args.out_dir) / f"execution-public-{args.hospital}.json"
    if not args.dry_run:
        out.parent.mkdir(parents=True, exist_ok=True)  # before the secret changes
    key = Ed25519PrivateKey.generate()
    seed_hex = key.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption()).hex()  # what the client reads
    pub_b64 = b64url(key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw))
    public = {"hospital": args.hospital.upper(), "org_id": org_id, "member_id": sub, "sub": sub,
              "pub_b64": pub_b64, "jkt": jkt(pub_b64)}

    if not args.dry_run:
        stored = subprocess.run(
            ["aws", "secretsmanager", "put-secret-value", "--profile", args.profile, "--region", args.region,
             "--secret-id", secret_id, "--secret-string", "file:///dev/stdin",
             "--query", "VersionId", "--output", "text"],
            input=seed_hex, text=True, capture_output=True,
        )
        if stored.returncode != 0:
            print(f"put-secret-value failed: {stored.stderr.strip()}", file=sys.stderr)
            return 1
        public["secret_id"] = secret_id
        public["secret_version"] = stored.stdout.strip()
    del key, seed_hex
    print(json.dumps(public))  # first, so the public half survives a failed write
    if not args.dry_run:
        out.write_text(json.dumps(public, indent=2) + "\n", encoding="utf-8")
        print(f"stored in {secret_id} (version {public['secret_version']}); public half in {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
