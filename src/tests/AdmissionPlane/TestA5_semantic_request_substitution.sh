#!/usr/bin/env bash
set -uo pipefail

# TestA5_semantic_request_substitution.sh
#
# Security invariant:
#   A holder proof for one governed request must not authorize a semantically
#   different request, even when both requests are within the holder's ECT
#   capability.
#
# Verdict contract:
#   rc=0   attack properly executed and BLOCKED
#   rc=1   attack properly executed and VULNERABILITY CONFIRMED
#   rc=2   INCONCLUSIVE because setup/precondition did not reach adjudication
#   rc=70  HARNESS/LOCAL EXECUTION ERROR

ENVELOPE_ID="${1:-}"
[[ -n "${ENVELOPE_ID}" ]] || {
  echo "Usage: $0 <active-envelope-id>" >&2
  exit 70
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

RUN_ID="${RUN_ID:-local-pathmnist-ab-001}"
HUB_URL="${HUB_URL:-http://127.0.0.1:8080}"
ISSUER_HOST="${ISSUER_HOST:-issuer-hospitala.local}"
ISSUER_PORT="${ISSUER_PORT:-9443}"
ISSUER_IP="${ISSUER_IP:-127.0.0.1}"
ISSUER_URL="https://${ISSUER_HOST}:${ISSUER_PORT}/mint"

DPOP_HTU="${DPOP_HTU:-https://verifier.local/admission/check}"
MINT_PROOF_HTU="${MINT_PROOF_HTU:-urn:openhealth:issuer:mint}"

INTENDED_TISSUE="${INTENDED_TISSUE:-mucus}"
SUBSTITUTED_TISSUE="${SUBSTITUTED_TISSUE:-lymphocytes}"

CA="${SRC_DIR}/vfp-governance/verifier/certs/ca.crt"
A_CRT="${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.crt"
A_KEY="${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.key"
AUDREY_PRIVATE="${SRC_DIR}/../secrets/holder_keys/Audrey.privhex"
GEN_MEMBER_KEYS="${SRC_DIR}/tools/gen_member_keys.py"
MAKE_DPOP="${SRC_DIR}/tools/make_dpop_jwt_eddsa.py"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

blocked() {
  printf '\n\033[32mA5 BLOCKED\033[0m\n'
  printf '%s\n' "$*"
  exit 0
}

vulnerable() {
  printf '\n\033[31mA5 VULNERABILITY CONFIRMED\033[0m\n'
  printf '%s\n' "$*"
  exit 1
}

inconclusive() {
  printf '\n\033[33mA5 INCONCLUSIVE\033[0m\n'
  printf '%s\n' "$*" >&2
  exit 2
}

error() {
  printf '\n\033[33mA5 HARNESS ERROR\033[0m\n'
  printf '%s\n' "$*" >&2
  exit 70
}

for cmd in curl jq python3; do
  command -v "${cmd}" >/dev/null 2>&1 || error "missing command ${cmd}"
done

for f in "${CA}" "${A_CRT}" "${A_KEY}" "${AUDREY_PRIVATE}" \
         "${GEN_MEMBER_KEYS}" "${MAKE_DPOP}"; do
  [[ -s "${f}" ]] || error "missing file ${f}"
done

echo "== 1. Derive Audrey holder identity =="

IDENTITY="$(
  python3 "${GEN_MEMBER_KEYS}" \
    --derive \
    --private-key "${AUDREY_PRIVATE}" \
    --format json
)" || error "cannot derive Audrey holder identity"

PUB_B64="$(jq -er '.pub_b64' <<<"${IDENTITY}")" || error "missing pub_b64"
PRIV_HEX="$(tr -d '\r\n' <"${AUDREY_PRIVATE}")"
[[ -n "${PRIV_HEX}" ]] || error "empty Audrey private key"

echo "== 2. Mint Audrey ECT =="

MINT_NONCE="mint-nonce-A5-$(python3 -c 'import secrets; print(secrets.token_urlsafe(12))')"
MINT_JTI="mint-jti-A5-$(python3 -c 'import uuid; print(uuid.uuid4())')"

MINT_DPOP="$(
  python3 "${MAKE_DPOP}" \
    "${PRIV_HEX}" \
    "${PUB_B64}" \
    "${MINT_NONCE}" \
    "${MINT_JTI}" \
    POST \
    "${MINT_PROOF_HTU}" \
    "${ENVELOPE_ID}"
)" || error "could not produce Audrey mint proof"

MINT_BODY="$(
  jq -nc \
    --arg e "${ENVELOPE_ID}" \
    --arg dpop "${MINT_DPOP}" \
    '{sub:"Audrey",envelope_id:$e,holder_dpop:$dpop}'
)"

MINT_STATUS="$(
  curl -sS \
    --resolve "${ISSUER_HOST}:${ISSUER_PORT}:${ISSUER_IP}" \
    --cacert "${CA}" \
    --cert "${A_CRT}" \
    --key "${A_KEY}" \
    -o "${TMP}/mint.json" \
    -w '%{http_code}' \
    -H 'content-type: application/json' \
    -d "${MINT_BODY}" \
    "${ISSUER_URL}"
)" || error "issuer mint request failed"

[[ "${MINT_STATUS}" == "200" ]] || {
  jq . "${TMP}/mint.json" >&2 2>/dev/null || true
  inconclusive "Audrey mint returned HTTP ${MINT_STATUS}"
}

ECT="$(jq -r '.ect // empty' "${TMP}/mint.json")"
[[ -n "${ECT}" && "${ECT}" == *.*.* ]] || error "issuer returned no compact ECT"

ECT_CLAIMS="$(
python3 - "${ECT}" <<'PY'
import base64, json, sys
parts = sys.argv[1].split(".")
if len(parts) != 3:
    raise SystemExit(2)
payload = parts[1] + "=" * (-len(parts[1]) % 4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(payload))))
PY
)" || error "cannot decode ECT"

for tissue in "${INTENDED_TISSUE}" "${SUBSTITUTED_TISSUE}"; do
  printf '%s\n' "${ECT_CLAIMS}" | jq -e --arg t "${tissue}" '
    [.cap[]?
      | select(
          .resource=="pathmnist-colon-pathology"
          and .action=="query_model"
          and .purpose=="approved_model_query"
        )
      | .scope.pathology_labels[]?
    ] | index($t) != null
  ' >/dev/null || inconclusive "${tissue} is not inside Audrey query capability"
done

echo "✓ Both tissues are inside the same Audrey query capability"

make_query_dpop() {
  local signed_tissue="$1"
  local nonce="$2"
  local jti="$3"

  python3 - \
    "${PRIV_HEX}" \
    "${PUB_B64}" \
    "${nonce}" \
    "${jti}" \
    "${DPOP_HTU}" \
    "${ENVELOPE_ID}" \
    "${RUN_ID}" \
    "${signed_tissue}" <<'PY'
import base64
import hashlib
import json
import sys
import time
from nacl import signing

priv_hex, pub_b64, nonce, jti, htu, envelope_id, run_id, tissue = sys.argv[1:]

def b64u(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")

def enc(value) -> str:
    return b64u(json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8"))

governed_request = {
    "envelope_id": envelope_id,
    "run_id": run_id,
    "resource": "pathmnist-colon-pathology",
    "action": "query_model",
    "purpose": "approved_model_query",
    "requested_tissues": [tissue],
}

canonical = json.dumps(
    governed_request,
    sort_keys=True,
    separators=(",", ":"),
    ensure_ascii=False,
).encode("utf-8")

request_hash = "sha256:" + hashlib.sha256(canonical).hexdigest()

header = {
    "typ": "dpop+jwt",
    "alg": "EdDSA",
    "jwk": {"kty": "OKP", "crv": "Ed25519", "x": pub_b64},
}

claims = {
    "htu": htu,
    "htm": "POST",
    "iat": int(time.time()),
    "jti": jti,
    "nonce": nonce,
    "envelope_id": envelope_id,
    "request_hash": request_hash,
}

h = enc(header)
p = enc(claims)
signing_input = f"{h}.{p}".encode("ascii")
sig = signing.SigningKey(bytes.fromhex(priv_hex)).sign(signing_input).signature
print(f"{h}.{p}.{b64u(sig)}")
PY
}

invoke_inference() {
  local body_tissue="$1"
  local nonce="$2"
  local jti="$3"
  local dpop="$4"
  local response_file="$5"

  curl -sS \
    -o "${response_file}" \
    -w '%{http_code}' \
    -X POST "${HUB_URL}/user/inference" \
    -H 'content-type: application/json' \
    -H "Authorization: ECT ${ECT}" \
    -H "DPoP: ${dpop}" \
    -H "X-DPoP-Nonce: ${nonce}" \
    -d "$(
      jq -nc \
        --arg e "${ENVELOPE_ID}" \
        --arg r "${RUN_ID}" \
        --arg t "${body_tissue}" \
        --arg j "${jti}" '
        {
          principal:"Audrey",
          envelope_id:$e,
          run_id:$r,
          requested_tissue:$t,
          jti:$j,
          topk:3
        }'
    )"
}

echo
echo "== 3. Positive control: intended request =="

POS_NONCE="nonce-A5-positive-$(python3 -c 'import secrets; print(secrets.token_urlsafe(12))')"
POS_JTI="jti-A5-positive-$(python3 -c 'import uuid; print(uuid.uuid4())')"
POS_DPOP="$(make_query_dpop "${INTENDED_TISSUE}" "${POS_NONCE}" "${POS_JTI}")" || \
  error "could not produce positive-control DPoP"

POS_STATUS="$(
  invoke_inference \
    "${INTENDED_TISSUE}" \
    "${POS_NONCE}" \
    "${POS_JTI}" \
    "${POS_DPOP}" \
    "${TMP}/positive.json"
)" || error "positive-control request failed at transport layer"

[[ "${POS_STATUS}" == "200" ]] || {
  jq . "${TMP}/positive.json" >&2 2>/dev/null || true
  inconclusive "positive control returned HTTP ${POS_STATUS}"
}

POS_ALLOW="$(jq -r '.admission.allow // empty' "${TMP}/positive.json")"
POS_REASON="$(jq -r '.admission.reason // empty' "${TMP}/positive.json")"

[[ "${POS_ALLOW}" == "true" ]] || {
  jq . "${TMP}/positive.json" >&2 2>/dev/null || true
  inconclusive "intended request was not admitted (${POS_REASON:-unknown})"
}

echo "✓ Intended request with matching request_hash was admitted"

echo
echo "== 4. Attack: intended proof semantics, substituted request body =="

ATTACK_NONCE="nonce-A5-attack-$(python3 -c 'import secrets; print(secrets.token_urlsafe(12))')"
ATTACK_JTI="jti-A5-attack-$(python3 -c 'import uuid; print(uuid.uuid4())')"
ATTACK_DPOP="$(make_query_dpop "${INTENDED_TISSUE}" "${ATTACK_NONCE}" "${ATTACK_JTI}")" || \
  error "could not produce attack DPoP"

ATTACK_STATUS="$(
  invoke_inference \
    "${SUBSTITUTED_TISSUE}" \
    "${ATTACK_NONCE}" \
    "${ATTACK_JTI}" \
    "${ATTACK_DPOP}" \
    "${TMP}/attack.json"
)" || error "attack request failed at transport layer"

[[ "${ATTACK_STATUS}" == "200" ]] || {
  jq . "${TMP}/attack.json" >&2 2>/dev/null || true
  inconclusive "attack request returned HTTP ${ATTACK_STATUS}"
}

ATTACK_ALLOW="$(jq -r '.admission.allow // empty' "${TMP}/attack.json")"
ATTACK_REASON="$(jq -r '.admission.reason // empty' "${TMP}/attack.json")"
ATTACK_EXECUTED="$(jq -r '.executed // false' "${TMP}/attack.json")"

echo
echo "Attack response:"
jq '{
  admission: .admission,
  executed: .executed,
  request: .request
}' "${TMP}/attack.json"

if [[ "${ATTACK_ALLOW}" == "true" ]]; then
  vulnerable \
    "Audrey proof committed to ${INTENDED_TISSUE} but Gatekeeper admitted ${SUBSTITUTED_TISSUE}."
fi

if [[ "${ATTACK_REASON}" != "dpop_request_hash_mismatch" ]]; then
  inconclusive \
    "substituted request was denied for unrelated reason: ${ATTACK_REASON:-unknown}"
fi

[[ "${ATTACK_EXECUTED}" != "true" ]] || \
  vulnerable "request_hash mismatch was reported but substituted request still executed"

blocked \
  "Semantic substitution was rejected with dpop_request_hash_mismatch; the holder proof is bound to the exact governed query."
