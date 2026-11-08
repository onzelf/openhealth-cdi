"""I0: local representation of a verified admission-derived relationship.

This module does NOT issue a BADGE, authenticate an ECT or enforce an execution
boundary. Only the Hub's trusted response from Gatekeeper's /admission/check may
be passed to it, after Gatekeeper has validated the ECT and holder DPoP proof.
The resulting value is diagnostic integration evidence, NEVER a bearer credential.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from typing import Any, Mapping


class InvalidQualification(ValueError):
    """Admission cannot be safely projected into a qualified traversal."""


def _required_string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise InvalidQualification(f"invalid_{field}")
    return value


def _digest(value: Mapping[str, Any]) -> str:
    canonical = json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")
    return "sha256:" + hashlib.sha256(canonical).hexdigest()


@dataclass(frozen=True)
class QualifiedTraversal:
    """Immutable projection of an ALLOW decision, not independent authority.

    The public-key thumbprint is a *holder binding*, not an authorization
    principal. No human/agent identity, name or actor type appears here.
    """

    envelope_id: str
    admission_decision_id: str
    holder_key_thumbprint: str
    context_sha256: str
    request_jti: str
    policy_hash: str

    def evidence(self) -> dict[str, str]:
        return {
            "kind": "admission_projection_not_credential",
            "schema_version": "ice.traversal.i0",
            "envelope_id": self.envelope_id,
            "admission_decision_id": self.admission_decision_id,
            "holder_key_thumbprint": self.holder_key_thumbprint,
            "context_sha256": self.context_sha256,
            "request_jti": self.request_jti,
            "policy_hash": self.policy_hash,
        }


def project_admitted_traversal(
    *,
    admission: Mapping[str, Any],
    checked_request: Mapping[str, Any],
    verified_ect_claims: Mapping[str, Any],
) -> QualifiedTraversal:
    """Project a *Gatekeeper-verified* ALLOW onto a relation description.

    The caller must obtain `admission` directly from the mutually authenticated
    Gatekeeper channel that verified `verified_ect_claims` and DPoP. This code
    deliberately cannot validate a self-declared ALLOW or replace the verifier.
    """
    if admission.get("allow") is not True:
        raise InvalidQualification("admission_not_allow")

    decision_id = _required_string(admission.get("decision_id"), "decision_id")
    envelope_id = _required_string(checked_request.get("envelope_id"), "envelope_id")
    if verified_ect_claims.get("envelope_id") != envelope_id:
        raise InvalidQualification("ect_envelope_mismatch")
    cnf = verified_ect_claims.get("cnf")
    if not isinstance(cnf, dict):
        raise InvalidQualification("invalid_holder_key_binding")
    jkt = _required_string(cnf.get("jkt"), "holder_key_thumbprint")
    jti = _required_string(checked_request.get("jti"), "request_jti")
    policy = verified_ect_claims.get("policy") or {}
    if not isinstance(policy, dict):
        raise InvalidQualification("invalid_ect_policy")
    policy_hash = _required_string(policy.get("policy_hash"), "policy_hash")

    for field in ("run_id", "resource", "action", "purpose"):
        _required_string(checked_request.get(field), field)
    tissues = checked_request.get("requested_tissues")
    if not isinstance(tissues, list) or not tissues:
        raise InvalidQualification("invalid_requested_tissues")
    for tissue in tissues:
        _required_string(tissue, "requested_tissue")
    for optional_field in ("derivative_representation", "governed_value_id"):
        v = checked_request.get(optional_field)
        if v is not None:
            _required_string(v, optional_field)

    try:
        context_digest = _digest(dict(checked_request))
    except (TypeError, ValueError, OverflowError) as exc:
        raise InvalidQualification("unhashable_traversal_context") from exc

    return QualifiedTraversal(
        envelope_id=envelope_id,
        admission_decision_id=decision_id,
        holder_key_thumbprint=jkt,
        context_sha256=context_digest,
        request_jti=jti,
        policy_hash=policy_hash,
    )
