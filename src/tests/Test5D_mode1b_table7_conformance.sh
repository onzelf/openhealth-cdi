#!/usr/bin/env bash
set -euo pipefail

# Test5D — executable reproduction of paper Table 7.
# Usage: ./Test5D_mode1b_table7_conformance.sh <active-envelope-id>
#
# Decision-plane rows reproduced here:
#   row 1 DENY / row 2 ALLOW / row 3 ALLOW / row 5 DENY
# Row 4 requires an actual governed W and is evidenced by Test5E.

ENVELOPE_ID="${1:-}"
[[ -n "${ENVELOPE_ID}" ]] || {
  echo "Usage: $0 <active-envelope-id>" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ISSUER_IP="${ISSUER_IP:-192.168.1.25}"
ISSUER_PORT="${ISSUER_PORT:-9443}"
VERIFIER_IP="${VERIFIER_IP:-192.168.1.25}"
VERIFIER_PORT="${VERIFIER_PORT:-8443}"
RUN_ID="${RUN_ID:-local-pathmnist-ab-001}"
HAL_CONTAINER="${HAL_CONTAINER:-hal}"
DPOP_HTU="https://verifier.local/admission/check"
TISSUE="${TISSUE:-colorectal_adenocarcinoma_epithelium}"
DERIVATIVE_REPRESENTATION="blurred_image_with_qualitative_accuracy"

CA="${SRC_DIR}/vfp-governance/verifier/certs/ca.crt"
A_CRT="${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.crt"
A_KEY="${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.key"
HUB_CRT="${SRC_DIR}/vfp-governance/verifier/certs/hub.crt"
HUB_KEY="${SRC_DIR}/vfp-governance/verifier/certs/hub.key"
EVIDENCE_PUBLIC_KEY="${SRC_DIR}/vfp-governance/verifier/certs/fcac-evidence.pub"
EVIDENCE_VERIFIER="${SRC_DIR}/tools/verify_fcac_evidence.py"
EVIDENCE_KEY_KID="${EVIDENCE_KEY_KID:-fcac-evidence-key-1}"
DECISIONS_DIR="${SRC_DIR}/vfp-governance/verifier/state/events/decisions"
AUDREY_PRIVATE="${SRC_DIR}/vfp-governance/verifier/vault/holder_keys/Audrey.privhex"
GEN_MEMBER_KEYS="${SRC_DIR}/tools/gen_member_keys.py"
MAKE_DPOP="${SRC_DIR}/tools/make_dpop_jwt_eddsa.py"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

pass() { printf '\033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }
section() { printf '\n============================================================\n%s\n============================================================\n' "$1"; }

for cmd in curl jq python3 docker; do
  command -v "${cmd}" >/dev/null 2>&1 || fail "Missing command: ${cmd}"
done
for f in "${CA}" "${A_CRT}" "${A_KEY}" "${HUB_CRT}" "${HUB_KEY}" \
  "${EVIDENCE_PUBLIC_KEY}" "${EVIDENCE_VERIFIER}" "${AUDREY_PRIVATE}" \
  "${GEN_MEMBER_KEYS}" "${MAKE_DPOP}"; do
  [[ -s "${f}" ]] || fail "Missing file: ${f}"
done

issuer_curl() {
  curl -sS --resolve "issuer-hospitala.local:${ISSUER_PORT}:${ISSUER_IP}" \
    --cacert "${CA}" --cert "${A_CRT}" --key "${A_KEY}" "$@"
}

verifier_curl() {
  curl -sS --resolve "verifier.local:${VERIFIER_PORT}:${VERIFIER_IP}" \
    --cacert "${CA}" --cert "${HUB_CRT}" --key "${HUB_KEY}" "$@"
}

decode_ect() {
  python3 - "$1" <<'PY2'
import base64, json, sys
payload = sys.argv[1].split('.')[1]
payload += '=' * ((4 - len(payload) % 4) % 4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(payload)), indent=2, sort_keys=True))
PY2
}

hal_sign_dpop() {
  docker exec -i "${HAL_CONTAINER}" python - "$1" "$2" "${DPOP_HTU}" "${ENVELOPE_ID}" <<'PY2'
import base64, json, sys, time
from pathlib import Path
from cryptography.hazmat.primitives import serialization
nonce, jti, htu, envelope_id = sys.argv[1:5]
identity = Path('/var/lib/hal/identity')
key = serialization.load_pem_private_key((identity / 'holder.key').read_bytes(), password=None)
jwk = json.loads((identity / 'holder.jwk').read_text())
b64 = lambda raw: base64.urlsafe_b64encode(raw).rstrip(b'=').decode()
enc = lambda obj: b64(json.dumps(obj, sort_keys=True, separators=(',', ':')).encode())
header = enc({'typ': 'dpop+jwt', 'alg': 'EdDSA', 'jwk': jwk})
payload = enc({
    'htu': htu,
    'htm': 'POST',
    'iat': int(time.time()),
    'jti': jti,
    'nonce': nonce,
    'envelope_id': envelope_id,
})
print(f'{header}.{payload}.{b64(key.sign(f"{header}.{payload}".encode()))}')
PY2
}

AUDREY_IDENTITY="$(
  python3 "${GEN_MEMBER_KEYS}" \
    --derive \
    --private-key "${AUDREY_PRIVATE}" \
    --format json
)"
AUDREY_PUB_B64="$(jq -er '.pub_b64' <<<"${AUDREY_IDENTITY}")"
AUDREY_JKT="$(jq -er '.jkt' <<<"${AUDREY_IDENTITY}")"
AUDREY_PRIV_HEX="$(tr -d '\r\n' <"${AUDREY_PRIVATE}")"

audrey_sign_dpop() {
  python3 "${MAKE_DPOP}" \
    "${AUDREY_PRIV_HEX}" \
    "${AUDREY_PUB_B64}" \
    "$1" \
    "$2" \
    POST \
    "${DPOP_HTU}" \
    "${ENVELOPE_ID}"
}

ensure_member() {
  local subject="$1" member_id="$2" pub="$3" jkt="$4"
  local members existing_jkt body out
  members="$(issuer_curl "https://issuer-hospitala.local:${ISSUER_PORT}/members")"
  existing_jkt="$(printf '%s' "${members}" | jq -r --arg s "${subject}" \
    '.members[]? | select(.sub==$s) | .jkt' | head -n1)"
  if [[ -z "${existing_jkt}" ]]; then
    body="$(jq -nc --arg id "${member_id}" --arg sub "${subject}" \
      --arg pub "${pub}" --arg jkt "${jkt}" \
      '{org_id:"org://HospitalA",member_id:$id,sub:$sub,pub_b64:$pub,jkt:$jkt}')"
    out="$(issuer_curl -H 'content-type: application/json' -d "${body}" \
      "https://issuer-hospitala.local:${ISSUER_PORT}/members/register")"
    printf '%s' "${out}" | jq -e '.status == "ok"' >/dev/null \
      || fail "Registration failed for ${subject}"
  else
    [[ "${existing_jkt}" == "${jkt}" ]] \
      || fail "${subject} is enrolled with a different JKT"
  fi
}

mint_ect() {
  local subject="$1" out="$2" response
  response="$(issuer_curl -H 'content-type: application/json' \
    -d "$(jq -nc --arg s "${subject}" --arg e "${ENVELOPE_ID}" \
      '{sub:$s,envelope_id:$e}')" \
    "https://issuer-hospitala.local:${ISSUER_PORT}/mint")"
  printf '%s' "${response}" | jq -e '.ect | type == "string" and length > 0' >/dev/null \
    || { printf '%s\n' "${response}" | jq . >&2; fail "ECT mint failed for ${subject}"; }
  printf '%s' "${response}" | jq -r '.ect' >"${out}"
}

verify_decision_record() {
  local decision_id="$1" subject="$2" action="$3" expected="$4" derivative="$5"
  local record="${DECISIONS_DIR}/${decision_id}.json"
  [[ -s "${record}" ]] || fail "Decision record missing: ${decision_id}"
  python3 "${EVIDENCE_VERIFIER}" \
    --public-key "${EVIDENCE_PUBLIC_KEY}" \
    --artifact "${record}" \
    --expected-type fcac_admission_decision \
    --expected-kid "${EVIDENCE_KEY_KID}" >/dev/null \
    || fail "Decision evidence verification failed: ${decision_id}"
  jq -e --arg s "${subject}" --arg a "${action}" --arg e "${expected}" \
    '.sub==$s and .requested_action==$a and .allow_or_deny==$e' \
    "${record}" >/dev/null || fail "Decision record contract mismatch: ${decision_id}"
  if [[ -n "${derivative}" ]]; then
    jq -e --arg d "${derivative}" '.request.derivative_representation==$d' \
      "${record}" >/dev/null || fail "Derivative policy flag missing from evidence"
  fi
}


CASE_LABELS=()
CASE_RESULTS=()
CASE_DECISION_IDS=()

admission_case() {
  local case_no="$1" label="$2" signer="$3" subject="$4" ect="$5"
  local resource="$6" action="$7" purpose="$8" tissue="$9"
  local derivative="${10}" expected="${11}" expected_reason="${12}"
  local nonce jti dpop body response allow reason decision_id

  nonce="nonce-$(python3 -c 'import secrets; print(secrets.token_urlsafe(12))')"
  jti="jti-$(python3 -c 'import secrets; print(secrets.token_urlsafe(12))')"
  if [[ "${signer}" == "hal" ]]; then
    dpop="$(hal_sign_dpop "${nonce}" "${jti}")"
  else
    dpop="$(audrey_sign_dpop "${nonce}" "${jti}")"
  fi

  body="$(jq -nc \
    --arg e "${ENVELOPE_ID}" --arg r "${RUN_ID}" \
    --arg resource "${resource}" --arg action "${action}" --arg purpose "${purpose}" \
    --arg tissue "${tissue}" --arg jti "${jti}" --arg derivative "${derivative}" \
    '{envelope_id:$e,run_id:$r,resource:$resource,action:$action,purpose:$purpose,
      requested_tissues:[$tissue],jti:$jti}
     + (if $derivative == "" then {} else {derivative_representation:$derivative} end)')"

  response="$(verifier_curl \
    -H "Authorization: ECT ${ect}" \
    -H "DPoP: ${dpop}" \
    -H "X-DPoP-Nonce: ${nonce}" \
    -H 'content-type: application/json' \
    -d "${body}" \
    "https://verifier.local:${VERIFIER_PORT}/admission/check")"

  allow="$(printf '%s' "${response}" | jq -r '.allow')"
  reason="$(printf '%s' "${response}" | jq -r '.reason // ""')"
  decision_id="$(printf '%s' "${response}" | jq -r '.decision_id // empty')"
  [[ -n "${decision_id}" ]] || { printf '%s\n' "${response}" | jq . >&2; fail "Case ${case_no}: no decision_id"; }

  if [[ "${expected}" == "ALLOW" ]]; then
    [[ "${allow}" == "true" ]] || { printf '%s\n' "${response}" | jq . >&2; fail "Case ${case_no}: expected ALLOW"; }
  else
    [[ "${allow}" == "false" ]] || { printf '%s\n' "${response}" | jq . >&2; fail "Case ${case_no}: expected DENY"; }
  fi
  if [[ -n "${expected_reason}" ]]; then
    [[ "${reason}" == "${expected_reason}" ]] \
      || fail "Case ${case_no}: expected reason ${expected_reason}, got ${reason:-none}"
  fi

  if [[ "${allow}" == "true" ]]; then
    observed="ALLOW"
  else
    observed="DENY"
  fi


  verify_decision_record "${decision_id}" "${subject}" "${action}" "${expected}" "${derivative}"

  CASE_LABELS+=("${label}")
  CASE_RESULTS+=("${observed}")
  CASE_DECISION_IDS+=("${decision_id}")

  pass "Table 7 case ${case_no}: ${label} -> ${observed}"
}

section "1. Holder identities and issuer bindings"

docker inspect "${HAL_CONTAINER}" >/dev/null 2>&1 || fail "Hal container is unavailable"
HAL_JWK="$(docker exec "${HAL_CONTAINER}" cat /var/lib/hal/identity/holder.jwk)"
HAL_JKT="$(docker exec "${HAL_CONTAINER}" cat /var/lib/hal/identity/holder.jkt | tr -d '\r\n')"
HAL_PUB="$(printf '%s' "${HAL_JWK}" | jq -r '.x // empty')"
[[ -n "${HAL_PUB}" && -n "${HAL_JKT}" ]] || fail "Hal public identity is incomplete"

ensure_member "Hal" "hal-mode1b" "${HAL_PUB}" "${HAL_JKT}"
ensure_member "Audrey" "audrey-mode1b" "${AUDREY_PUB_B64}" "${AUDREY_JKT}"
pass "Hal and Audrey holder identities match Hospital A enrollment"

section "2. Envelope-bound credentials"

mint_ect "Hal" "${TMP}/hal.ect"
mint_ect "Audrey" "${TMP}/audrey.ect"
HAL_ECT="$(cat "${TMP}/hal.ect")"
AUDREY_ECT="$(cat "${TMP}/audrey.ect")"
decode_ect "${HAL_ECT}" >"${TMP}/hal-claims.json"
decode_ect "${AUDREY_ECT}" >"${TMP}/audrey-claims.json"

jq -e --arg e "${ENVELOPE_ID}" --arg jkt "${HAL_JKT}" '
  .sub=="Hal" and .actor_type=="agent" and .envelope_id==$e and .cnf.jkt==$jkt
  and (.cap_profiles | index("capset:pathmnist_bounded_agent") != null)
  and ([.cap[].action] | index("bounded_inference") != null)
  and ([.cap[].action] | index("unbind") != null)
  and (
    [.cap[]
      | select(.action=="bounded_inference")
      | .scope.pathology_labels[]?] | sort
    ==
    ["colorectal_adenocarcinoma_epithelium","mucus"]
  )
  and (
    [.cap[]
      | select(.action=="unbind")
      | .scope.pathology_labels[]?] | sort
    ==
    ["colorectal_adenocarcinoma_epithelium","mucus"]
  )
  and ([.cap[].action] | index("join_envelope") == null)
' "${TMP}/hal-claims.json" >/dev/null || fail "Hal ECT contract mismatch"

jq -e --arg e "${ENVELOPE_ID}" --arg jkt "${AUDREY_JKT}" '
  .sub=="Audrey" and .actor_type=="human" and .envelope_id==$e and .cnf.jkt==$jkt
  and (.cap_profiles | index("capset:pathmnist_other_tissue_reader") != null)
  and (.cap_profiles | index("capset:pathmnist_derivative_reader") != null)
  and ([.cap[] | select(.action=="consume_derivative")] | length == 1)
  and (
    [.cap[]
      | select(.action=="consume_derivative")
      | .scope.pathology_labels[]?] | sort
    ==
    ["colorectal_adenocarcinoma_epithelium","mucus"]
  )
  and ([.cap[] | select(.action=="query_model") | .scope.pathology_labels[]?]
       | index("colorectal_adenocarcinoma_epithelium") == null)
' "${TMP}/audrey-claims.json" >/dev/null || fail "Audrey ECT contract mismatch"
pass "Credentials preserve separate relations and the two-tissue Mode 1B scope"

section "3. Table 7 executable conformance"

admission_case 1 \
  "requester asks for unrestricted cancer source" \
  audrey Audrey "${AUDREY_ECT}" \
  pathmnist-colon-pathology query_model approved_model_query "${TISSUE}" \
  "" DENY capability_scope_exceeded

admission_case 2 \
  "agent performs bounded inference" \
  hal Hal "${HAL_ECT}" \
  pathmnist-colon-pathology bounded_inference bounded_model_inference "${TISSUE}" \
  "" ALLOW ""

admission_case 3 \
  "agent invokes policy-authorized unbind" \
  hal Hal "${HAL_ECT}" \
  pathmnist-colon-pathology unbind policy_authorized_derivation "${TISSUE}" \
  "${DERIVATIVE_REPRESENTATION}" ALLOW ""

# Table 7 row 4 is composition-dependent under exact-W semantics.
# consume_derivative must name the concrete W produced by the
# authorized Unbind, therefore this row is evidenced by Test5E.
CASE_LABELS+=("requester consumes exact governed derivative")
CASE_RESULTS+=("TEST5E")
CASE_DECISION_IDS+=("-")
pass "Table 7 case 4: exact-W consumption is evidenced by Test5E"

admission_case 5 \
  "agent attempts privileged governance operation" \
  hal Hal "${HAL_ECT}" \
  openhealth-pathmnist-ab join_envelope federated_participation "${TISSUE}" \
  "" DENY capability_violation

# Row 5 also requires the alternate privileged route to remain physically absent.
if docker exec -i "${HAL_CONTAINER}" python - <<'PY2'
import socket, sys
try:
    with socket.create_connection(("verifier-app", 9000), timeout=1):
        sys.exit(0)
except OSError:
    sys.exit(1)
PY2
then
  fail "Table 7 case 5: Hal unexpectedly reached verifier-app:9000"
fi
pass "Table 7 case 5 route check: verifier-app remains unreachable from Hal"

#section "4. Table 7 result"
section "4. Table 7 result"

printf '%-6s %-56s %-10s %s\n' \
  "CASE" "GOVERNED OPERATION" "OBSERVED" "DECISION ID"
printf '%s\n' \
  "---------------------------------------------------------------------------------------------------------------"

for i in "${!CASE_RESULTS[@]}"; do
  printf '%-6s %-56s %-10s %s\n' \
    "$((i + 1))" \
    "${CASE_LABELS[$i]}" \
    "${CASE_RESULTS[$i]}" \
    "${CASE_DECISION_IDS[$i]}"
done

printf '\n'
pass "TABLE 7 DECISION PLANE GREEN: rows 1, 2, 3 and 5 reproduced with signed evidence; row 4 composition evidence is provided by Test5E"
