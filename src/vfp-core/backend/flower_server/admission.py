"""Issue #7: bind Flower participation to OpenHealth admission.

Before each training round the server sends every sampled client a fresh,
server-generated challenge bound to the envelope, the run and the round. A
client takes part only if it signs that challenge with the Flower execution key
registered for an organisation the Hub admitted. The Hub passes those
organisation/key bindings in /bind_envelope; nothing the client says about
itself (fit metrics, /clients/register) is trusted, and at most one connection
per organisation takes part in a round.
"""

from __future__ import annotations

import base64
import secrets
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Dict, Iterable, List, Optional, Tuple

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from flwr.common import GetPropertiesIns

DOMAIN = "openhealth-flower-admission"


class AdmissionThresholdNotMet(RuntimeError):
    """Fewer admitted, proven clients than the round needs: fail closed."""


class EnvelopeExpired(RuntimeError):
    """The bound envelope's validity window has closed: no further rounds."""


def envelope_expired(valid_until: Any, now: float) -> bool:
    """True once the envelope's valid_until has passed. Only a bounded envelope is valid:
    a missing value, or one that cannot be read, counts as expired (fail closed)."""
    if valid_until in (None, ""):
        return True
    try:
        return now >= float(valid_until)
    except (TypeError, ValueError):
        return True


def admission_keys(binding: Dict[str, Any], guest_admitted: bool) -> Dict[str, str]:
    """org_id -> public execution key for the organisations allowed to train this run.

    Envelope participants, with keys their own issuers registered. A sponsored guest
    (Mode 1A, e.g. Hospital C) is added only after the Gatekeeper allowed its guest
    contribution; its key was registered by the sponsoring organisation's issuer.
    """
    participants = set(binding.get("participants") or [])
    keys = {
        org_id: key
        for org_id, key in (binding.get("participant_keys") or {}).items()
        if org_id in participants and key
    }
    if guest_admitted:
        for org_id, key in (binding.get("guest_keys") or {}).items():
            if key and org_id not in keys:
                keys[org_id] = key
    return keys


def challenge_message(
    envelope_id: str, run_id: str, server_round: int, nonce: str, org_id: str
) -> bytes:
    return "|".join(
        [DOMAIN, envelope_id, run_id, str(server_round), nonce, org_id]
    ).encode("utf-8")


def b64url_decode(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def verified_org(
    properties: Dict[str, Any],
    keys: Dict[str, str],
    envelope_id: str,
    run_id: str,
    server_round: int,
    nonce: str,
) -> Optional[str]:
    """The organisation this connection proved, or None."""
    org_id = str(properties.get("org_id") or "")
    signature = str(properties.get("admission_signature") or "")
    public_key = keys.get(org_id)
    if not public_key or not signature:
        return None
    try:
        Ed25519PublicKey.from_public_bytes(b64url_decode(public_key)).verify(
            b64url_decode(signature),
            challenge_message(envelope_id, run_id, server_round, nonce, org_id),
        )
    except (InvalidSignature, ValueError, TypeError):
        return None
    return org_id


def admit(
    instructions: Iterable[Tuple[Any, Any]],
    keys: Dict[str, str],
    envelope_id: str,
    run_id: str,
    server_round: int,
    timeout: float = 10.0,
) -> Tuple[List[Tuple[Any, Any]], Dict[str, str], List[Tuple[str, str]]]:
    """Challenge each sampled client; keep one proven connection per organisation.

    The challenges run in parallel, so clients that never answer cost one timeout per
    pass rather than one each. Decisions follow the sampling order, as before.

    Returns (admitted instructions, {cid: org_id}, [(cid, reason)] rejected).
    """
    instructions = list(instructions)

    def challenge(proxy: Any) -> Tuple[str, Optional[Dict[str, Any]], Optional[str]]:
        nonce = secrets.token_urlsafe(24)
        config = {
            "admission_nonce": nonce,
            "envelope_id": envelope_id,
            "run_id": run_id,
            "round": server_round,
        }
        try:
            response = proxy.get_properties(
                GetPropertiesIns(config=config),
                timeout=timeout,
                group_id=server_round,
            )
            return nonce, dict(response.properties or {}), None
        except Exception as exc:  # a client that cannot answer is not admitted
            return nonce, None, f"no_proof:{type(exc).__name__}"

    # At most 64 challenges at once: far more silent connections would still add one
    # timeout per 64 (a limit on connections per subnet would be the next step).
    with ThreadPoolExecutor(max_workers=max(1, min(len(instructions), 64))) as pool:
        answers = list(pool.map(challenge, [proxy for proxy, _ in instructions]))

    admitted: List[Tuple[Any, Any]] = []
    orgs: Dict[str, str] = {}
    rejected: List[Tuple[str, str]] = []
    for (proxy, fit_ins), (nonce, properties, error) in zip(instructions, answers):
        if properties is None:
            rejected.append((proxy.cid, str(error)))
            continue
        org_id = verified_org(
            properties, keys, envelope_id, run_id, server_round, nonce
        )
        if org_id is None:
            claimed = str(properties.get("org_id") or "none")[:80]  # a rogue chooses this
            rejected.append((proxy.cid, f"invalid_proof:{claimed}"))
            continue
        if org_id in orgs.values():
            rejected.append((proxy.cid, f"duplicate_org:{org_id}"))
            continue
        admitted.append((proxy, fit_ins))
        orgs[proxy.cid] = org_id
    return admitted, orgs, rejected
