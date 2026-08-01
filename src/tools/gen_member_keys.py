#!/usr/bin/env python3
"""Provision or inspect Ed25519 holder proof-of-possession keys.

Generation remains the default for backward compatibility. Derivation is
strictly non-mutating and is intended for runtime and smoke-test inspection of
an already provisioned private key.
"""

from __future__ import annotations

import argparse
import base64
import datetime
import hashlib
import json
import pathlib
import sys
from typing import Any, Dict

from nacl import encoding, signing


def b64url_no_pad(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def rfc7638_thumbprint_okp_ed25519(pub_b64u: str) -> str:
    jwk = {
        "crv": "Ed25519",
        "kty": "OKP",
        "x": pub_b64u,
    }
    canonical = json.dumps(
        jwk,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")
    return b64url_no_pad(hashlib.sha256(canonical).digest())


def identity_from_signing_key(signing_key: signing.SigningKey) -> Dict[str, str]:
    public_b64 = b64url_no_pad(signing_key.verify_key.encode())
    return {
        "priv_hex": signing_key.encode(
            encoder=encoding.HexEncoder
        ).decode("ascii"),
        "pub_b64": public_b64,
        "jkt": rfc7638_thumbprint_okp_ed25519(public_b64),
    }


def read_signing_key(path: pathlib.Path) -> signing.SigningKey:
    try:
        private_hex = path.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise ValueError(f"cannot_read_private_key:{path}:{exc}") from exc

    try:
        private_bytes = bytes.fromhex(private_hex)
    except ValueError as exc:
        raise ValueError(f"invalid_private_key_hex:{path}") from exc

    if len(private_bytes) != 32:
        raise ValueError(
            f"invalid_private_key_length:{path}:expected_32_bytes:got_{len(private_bytes)}"
        )

    try:
        return signing.SigningKey(private_bytes)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"invalid_ed25519_private_key:{path}") from exc


def emit_identity(identity: Dict[str, str], output_format: str) -> None:
    public_identity = {
        "pub_b64": identity["pub_b64"],
        "jkt": identity["jkt"],
    }
    if output_format == "json":
        print(json.dumps(public_identity, sort_keys=True))
        return

    print(f"PUBB64: {public_identity['pub_b64']}")
    print(f"JKT: {public_identity['jkt']}")


def generate_member(args: argparse.Namespace) -> None:
    if not args.who:
        raise ValueError("--who is required when generating member keys")
    if not args.org:
        raise ValueError("--org is required when generating member keys")

    identity = identity_from_signing_key(signing.SigningKey.generate())
    output_dir = pathlib.Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    private_path = output_dir / f"{args.who}.privhex"
    public_path = output_dir / f"{args.who}.pubb64"
    jkt_path = output_dir / f"{args.who}.jkt"
    registration_path = output_dir / f"{args.who}.register.json"

    private_path.write_text(identity["priv_hex"], encoding="utf-8")
    public_path.write_text(identity["pub_b64"], encoding="utf-8")
    jkt_path.write_text(identity["jkt"], encoding="utf-8")

    registration: Dict[str, Any] = {
        "org_id": args.org,
        "member_id": args.who,
        "sub": args.who,
        "pub_b64": identity["pub_b64"],
        "jkt": identity["jkt"],
        "created_at": (
            datetime.datetime.now(datetime.timezone.utc)
            .replace(microsecond=0)
            .isoformat()
            .replace("+00:00", "Z")
        ),
    }
    registration_path.write_text(
        json.dumps(registration, indent=2),
        encoding="utf-8",
    )

    print(f"generated PRIVHEX: {identity['priv_hex']} for {args.who}")
    print(f"generated PUBB64 : {identity['pub_b64']} for {args.who}")
    print(f"generated JKT    : {identity['jkt']}")
    print(f"wrote registration payload: {registration_path}")


def derive_member(args: argparse.Namespace) -> None:
    if args.private_key is None:
        raise ValueError("--private-key is required with --derive")

    identity = identity_from_signing_key(read_signing_key(args.private_key))
    emit_identity(identity, args.format)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Generate member PoP keys and registration payloads, or derive "
            "public holder identity from an existing private key"
        )
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--generate",
        action="store_const",
        const="generate",
        dest="mode",
        help="Generate a new member keypair and registration payload (default)",
    )
    mode.add_argument(
        "--derive",
        action="store_const",
        const="derive",
        dest="mode",
        help="Derive public holder identity without writing files",
    )
    parser.set_defaults(mode="generate")

    parser.add_argument("--who", help="Member identity (sub)")
    parser.add_argument("--org", help="Organization identifier (org_id)")
    parser.add_argument(
        "--output-dir",
        default="holder_keys",
        help="Generation output directory (default: holder_keys)",
    )
    parser.add_argument(
        "--private-key",
        type=pathlib.Path,
        help="Existing 32-byte Ed25519 private seed encoded as hexadecimal",
    )
    parser.add_argument(
        "--format",
        choices=("text", "json"),
        default="text",
        help="Derivation output format (default: text)",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.mode == "derive":
            derive_member(args)
        else:
            generate_member(args)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
