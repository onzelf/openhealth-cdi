#!/usr/bin/env python3
"""
Inspect an Envelope Capability Token (ECT) without verifying its signature.

This tool validates the minting contract exposed by /mint_ect:

1. the token is a compact JWS with three segments;
2. the payload contains the expected envelope_id;
3. the payload contains a non-empty capability list;
4. at least one capability matches the expected
   resource/action/purpose and includes all required tissues;
5. no capability grants any forbidden tissue.

The cryptographic signature is intentionally not verified here. Signature
verification belongs to the gatekeeper admission path exercised by Test2A.
"""

from __future__ import annotations

import argparse
import base64
import json
import sys
from pathlib import Path
from typing import Any


class InspectionError(ValueError):
    """Raised when the ECT does not satisfy the expected minting contract."""


def decode_b64url_json(segment: str, label: str) -> dict[str, Any]:
    padding = "=" * ((4 - len(segment) % 4) % 4)
    try:
        decoded = base64.urlsafe_b64decode(segment + padding)
        value = json.loads(decoded.decode("utf-8"))
    except Exception as exc:
        raise InspectionError(f"invalid {label} segment: {exc}") from exc

    if not isinstance(value, dict):
        raise InspectionError(f"{label} segment must decode to a JSON object")
    return value


def parse_csv_values(values: list[str]) -> set[str]:
    result: set[str] = set()
    for value in values:
        for item in value.split(","):
            item = item.strip()
            if item:
                result.add(item)
    return result


def inspect_ect(
    token: str,
    expected_envelope_id: str,
    expected_resource: str,
    expected_action: str,
    expected_purpose: str,
    required_tissues: set[str],
    forbidden_tissues: set[str],
    expected_jkt: str | None,
) -> dict[str, Any]:
    parts = token.strip().split(".")
    if len(parts) != 3 or any(not part for part in parts):
        raise InspectionError(
            "ECT must be a compact JWS containing non-empty "
            "header.payload.signature segments"
        )

    header = decode_b64url_json(parts[0], "header")
    payload = decode_b64url_json(parts[1], "payload")

    actual_envelope_id = payload.get("envelope_id")
    if actual_envelope_id != expected_envelope_id:
        raise InspectionError(
            "envelope_id mismatch: "
            f"expected {expected_envelope_id!r}, found {actual_envelope_id!r}"
        )

    cnf = payload.get("cnf")
    if not isinstance(cnf, dict):
        raise InspectionError("ECT payload must contain a 'cnf' JSON object")

    actual_jkt = cnf.get("jkt")
    if not isinstance(actual_jkt, str) or not actual_jkt:
        raise InspectionError(
            "ECT payload must contain a non-empty 'cnf.jkt' string"
        )

    if expected_jkt is not None and actual_jkt != expected_jkt:
        raise InspectionError(
            "cnf.jkt mismatch: "
            f"expected {expected_jkt!r}, found {actual_jkt!r}"
        )

    capabilities = payload.get("cap")
    if not isinstance(capabilities, list) or not capabilities:
        raise InspectionError("ECT payload must contain a non-empty 'cap' list")

    matching_capabilities: list[dict[str, Any]] = []
    granted_tissues: set[str] = set()

    for index, capability in enumerate(capabilities):
        if not isinstance(capability, dict):
            raise InspectionError(f"cap[{index}] must be a JSON object")

        scope = capability.get("scope") or {}
        if not isinstance(scope, dict):
            raise InspectionError(f"cap[{index}].scope must be a JSON object")

        tissues = scope.get("pathology_labels") or []
        if not isinstance(tissues, list) or not all(
            isinstance(tissue, str) for tissue in tissues
        ):
            raise InspectionError(
                f"cap[{index}].scope.pathology_labels must be a list of strings"
            )

        tissue_set = set(tissues)
        granted_tissues.update(tissue_set)

        if (
            capability.get("resource") == expected_resource
            and capability.get("action") == expected_action
            and capability.get("purpose") == expected_purpose
            and required_tissues.issubset(tissue_set)
        ):
            matching_capabilities.append(capability)

    if not matching_capabilities:
        raise InspectionError(
            "no capability matches the expected resource/action/purpose "
            f"and required tissues {sorted(required_tissues)}"
        )

    forbidden_grants = granted_tissues.intersection(forbidden_tissues)
    if forbidden_grants:
        raise InspectionError(
            "ECT grants forbidden tissue classes: "
            + ", ".join(sorted(forbidden_grants))
        )

    return {
        "ok": True,
        "header": {
            "alg": header.get("alg"),
            "kid": header.get("kid"),
            "typ": header.get("typ"),
        },
        "envelope_id": actual_envelope_id,
        "capability_count": len(capabilities),
        "matching_capability_count": len(matching_capabilities),
        "required_tissues": sorted(required_tissues),
        "forbidden_tissues": sorted(forbidden_tissues),
        "granted_tissues": sorted(granted_tissues),
        "policy": payload.get("policy"),
        "cnf": cnf,
        "jkt": actual_jkt,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Inspect an ECT returned by /mint_ect."
    )
    token_group = parser.add_mutually_exclusive_group(required=True)
    token_group.add_argument(
        "--token",
        help="Compact ECT JWS. Prefer --token-file or --stdin to avoid shell history.",
    )
    token_group.add_argument(
        "--token-file",
        help="File containing the compact ECT JWS.",
    )
    token_group.add_argument(
        "--stdin",
        action="store_true",
        help="Read the compact ECT JWS from standard input.",
    )

    parser.add_argument("--expected-envelope-id", required=True)
    parser.add_argument("--expected-jkt-file",
        help=(
            "File containing the expected holder RFC 7638 JKT. "
            "When provided, it must match ECT payload cnf.jkt."
        ),
    )
    parser.add_argument(
        "--expected-resource",
        default="pathmnist-colon-pathology",
    )
    parser.add_argument(
        "--expected-action",
        default="query_model",
    )
    parser.add_argument(
        "--expected-purpose",
        default="approved_model_query",
    )
    parser.add_argument(
        "--require-tissue",
        action="append",
        default=[],
        help="Required tissue identifier; repeat or provide comma-separated values.",
    )
    parser.add_argument(
        "--forbid-tissue",
        action="append",
        default=[],
        help="Forbidden tissue identifier; repeat or provide comma-separated values.",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Do not print the successful inspection summary.",
    )
    return parser


def read_token(args: argparse.Namespace) -> str:
    if args.token is not None:
        return args.token.strip()
    if args.token_file is not None:
        try:
            return Path(args.token_file).read_text(encoding="utf-8").strip()
        except OSError as exc:
            raise InspectionError(
                f"cannot read token file {args.token_file!r}: {exc}"
            ) from exc
    return sys.stdin.read().strip()


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    required_tissues = parse_csv_values(args.require_tissue)
    forbidden_tissues = parse_csv_values(args.forbid_tissue)
    
    if not required_tissues:
        parser.error("at least one --require-tissue value is required")


    expected_jkt: str | None = None

    if args.expected_jkt_file is not None:
        try:
            expected_jkt = Path(args.expected_jkt_file).read_text(
                encoding="utf-8"
            ).strip()
        except OSError as exc:
            parser.error(
                f"cannot read expected JKT file "
                f"{args.expected_jkt_file!r}: {exc}"
            )

        if not expected_jkt:
            parser.error(
                f"expected JKT file {args.expected_jkt_file!r} is empty"
            )

    try:
        token = read_token(args)
        if not token:
            raise InspectionError("ECT token is empty")

        summary = inspect_ect(
            token=token,
            expected_envelope_id=args.expected_envelope_id,
            expected_resource=args.expected_resource,
            expected_action=args.expected_action,
            expected_purpose=args.expected_purpose,
            required_tissues=required_tissues,
            forbidden_tissues=forbidden_tissues,
            expected_jkt=expected_jkt,
        )
    except InspectionError as exc:
        print(f"ECT inspection failed: {exc}", file=sys.stderr)
        return 1

    if not args.quiet:
        print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
