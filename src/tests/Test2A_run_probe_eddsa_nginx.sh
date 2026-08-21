#!/usr/bin/env bash
# Test2A_run_probe_eddsa_nginx.sh
#
# Governance-side smoke test only.
#
# Direct path under test:
#   policy.json capset
#       -> POST /mint_ect
#       -> signed envelope-bound ECT
#       -> EdDSA DPoP
#       -> POST /admission/check
#       -> expected ALLOW / DENY decisions
#
# Deliberately outside this test:
#   - issuer.py
#   - issuer-side cap_profiles.json
#   - holder registry lookup
# Those belong to Test2B.
#
# Usage:
#   ./Test2A_run_probe_eddsa_nginx.sh <active-envelope-id>
#
#  or With the additional inspection:
#   INSPECT_MINTED_ECT=true ./Test2A_run_probe_eddsa_nginx.sh <active-envelope-id>
#
# Optional environment overrides:
#   VERIFIER_URL=https://verifier.local:8443
#   DPOP_HTU=https://verifier.local/admission/check
#   RUN_ID=local-pathmnist-ab-001
#   CAP_PROFILE=capset:pathmnist_other_tissue_reader

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOLS_DIR="${SRC_DIR}/tools"

VERIFIER_URL="${VERIFIER_URL:-https://verifier.local:8443}"
DPOP_HTU="${DPOP_HTU:-https://verifier.local/admission/check}"

RUN_ID="${RUN_ID:-local-pathmnist-ab-001}"
CAP_PROFILE="${CAP_PROFILE:-capset:pathmnist_other_tissue_reader}"

POLICY_JSON="${SRC_DIR}/vfp-governance/verifier/state/policy.json"

CAC="${SRC_DIR}/vfp-governance/verifier/certs/ca.crt"
HUB_CRT="${SRC_DIR}/vfp-governance/verifier/certs/hub.crt"
HUB_KEY="${SRC_DIR}/vfp-governance/verifier/certs/hub.key"

# Administrative mTLS identity required by nginx for /mint_ect.
MINT_CRT="${MINT_CRT:-${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.crt}"
MINT_KEY="${MINT_KEY:-${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.key}"

ENVELOPE_ID="${1:-}"
OTHER_ENVELOPE_ID="${ENVELOPE_ID}-different"
INSPECT_MINTED_ECT="${INSPECT_MINTED_ECT:-false}"

NBF="$(date -u -Iseconds -d '-60 seconds' | sed 's/+00:00/Z/')"
EXP="$(date -u -Iseconds -d '+5 minutes' | sed 's/+00:00/Z/')"

pass() {
  printf '\033[32m✓\033[0m %s\n' "$*"
}

fail() {
  printf '\033[31m✗\033[0m %s\n' "$*" >&2
  exit 1
}

section() {
  printf '\n\033[1m== %s ==\033[0m\n' "$*"
}

require_file() {
  local path="$1"
  [[ -s "${path}" ]] || fail "Missing or empty file: ${path}"
}

require_command() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || fail "Missing command: ${cmd}"
}

[[ -n "${ENVELOPE_ID}" ]] || fail \
  "Usage: $0 <active-envelope-id>"

for cmd in curl jq python3; do
  require_command "${cmd}"
done

for path in \
  "${POLICY_JSON}" \
  "${CAC}" \
  "${HUB_CRT}" \
  "${HUB_KEY}" \
  "${MINT_CRT}" \
  "${MINT_KEY}" \
  "${TOOLS_DIR}/gen_member_keys.py" \
  "${TOOLS_DIR}/make_dpop_jwt_eddsa.py"; do
  require_file "${path}"
done

CURL_HUB=(
  -sS
  --cacert "${CAC}"
  --cert "${HUB_CRT}"
  --key "${HUB_KEY}"
)

CURL_MINT=(
  -sS
  --cacert "${CAC}"
  --cert "${MINT_CRT}"
  --key "${MINT_KEY}"
)

section "0. Validate executable policy"

jq -e . "${POLICY_JSON}" >/dev/null \
  || fail "policy.json is invalid JSON"

jq -e \
  --arg profile "${CAP_PROFILE}" \
  '.cap_profiles[$profile].cap | type == "array" and length > 0' \
  "${POLICY_JSON}" >/dev/null \
  || fail "Missing or empty policy capset: ${CAP_PROFILE}"

OP_ID="$(
  jq -r \
    --arg profile "${CAP_PROFILE}" \
    '.cap_profiles[$profile].cap[0]' \
    "${POLICY_JSON}"
)"

jq -e \
  --arg op "${OP_ID}" \
  '.ops[$op] != null' \
  "${POLICY_JSON}" >/dev/null \
  || fail "Capset ${CAP_PROFILE} references missing operation: ${OP_ID}"

jq -e \
  --arg op "${OP_ID}" \
  '
    .ops[$op].resource == "pathmnist-colon-pathology"
    and .ops[$op].action == "query_model"
    and .ops[$op].purpose == "approved_model_query"
    and (.ops[$op].scope.pathology_labels | index("mucus") != null)
    and (.ops[$op].scope.pathology_labels | index("normal_colon_mucosa") != null)
    and (.ops[$op].scope.pathology_labels | index("lymphocytes") != null)
    and (.ops[$op].scope.pathology_labels | index("debris") == null)
  ' \
  "${POLICY_JSON}" >/dev/null \
  || fail "Other-tissue reader operation does not match the agreed PathMNIST scope"

jq -e \
  '.caveats.reserved_pathology_labels | index("background") != null' \
  "${POLICY_JSON}" >/dev/null \
  || fail "policy.json does not declare Background tissue as reserved"

pass "Policy capset and PathMNIST tissue scopes are coherent"

section "1. Wait for gatekeeper"

HEALTH=""
for _ in $(seq 1 40); do
  if HEALTH="$(curl "${CURL_HUB[@]}" "${VERIFIER_URL}/health" 2>/dev/null)"; then
    if printf '%s' "${HEALTH}" | jq -e '.ok == true' >/dev/null 2>&1; then
      break
    fi
  fi
  HEALTH=""
  sleep 0.25
done

[[ -n "${HEALTH}" ]] || fail "Gatekeeper /health is not ready"
printf '%s\n' "${HEALTH}" | jq .
HEALTH_POLICY_HASH="$(printf '%s' "${HEALTH}" | jq -r '.policy_hash')"

STATUS="$(
  curl "${CURL_HUB[@]}" \
    "${VERIFIER_URL}/status?state=ACTIVE"
)"
printf '%s\n' "${STATUS}" | jq .

printf '%s\n' "${STATUS}" | jq -e \
  --arg envelope "${ENVELOPE_ID}" \
  '.envelopes[] | select(.envelope_id == $envelope and .state == "ACTIVE")' \
  >/dev/null \
  || fail "Envelope is absent or not ACTIVE: ${ENVELOPE_ID}"

pass "Gatekeeper is ready and envelope is ACTIVE"

section "2. Generate holder-bound Ed25519 keys"

cd "${SCRIPT_DIR}"

python3 "${TOOLS_DIR}/gen_member_keys.py" \
  --org "org://HospitalA" \
  --who "Martinez" \
  | sed 's/^/[Martinez] /'

PUB_B64="$(tr -d '\r\n' < holder_keys/Martinez.pubb64)"
PRIV_HEX="$(tr -d '\r\n' < holder_keys/Martinez.privhex)"

[[ -n "${PUB_B64}" ]] || fail "Missing Martinez public key"
[[ -n "${PRIV_HEX}" ]] || fail "Missing Martinez private key"

pass "Holder key material generated"

section "3. Mint ECT directly through /mint_ect"

MINT_REQUEST="$(
  jq -nc \
    --arg pub "${PUB_B64}" \
    --arg profile "${CAP_PROFILE}" \
    --arg envelope "${ENVELOPE_ID}" \
    --arg sub "Martinez" \
    --arg actor_type "human" \
    --arg nbf "${NBF}" \
    --arg exp "${EXP}" \
    '{
      holder_pub_b64: $pub,
      cap_profiles: [$profile],
      envelope_id: $envelope,
      sub: $sub,
      actor_type: $actor_type,
      nbf: $nbf,
      exp: $exp
    }'
)"

printf '%s\n' "${MINT_REQUEST}" | jq .

MINT_RESPONSE="$(
  curl "${CURL_MINT[@]}" \
    -X POST "${VERIFIER_URL}/mint_ect" \
    -H 'content-type: application/json' \
    -d "${MINT_REQUEST}"
)"

printf '%s\n' "${MINT_RESPONSE}" | jq .

ECT="$(printf '%s' "${MINT_RESPONSE}" | jq -r '.ect_jws // empty')"
MINT_POLICY_HASH="$(printf '%s' "${MINT_RESPONSE}" | jq -r '.policy_hash // empty')"

[[ -n "${ECT}" ]] || fail "/mint_ect did not return ect_jws"
[[ "${MINT_POLICY_HASH}" == "${HEALTH_POLICY_HASH}" ]] || fail \
  "Minted ECT policy hash differs from active gatekeeper policy hash"

# Optional inspection of the minted ECT, if requested by the user.
if [[ "${INSPECT_MINTED_ECT:-false}" == "true" ]]; then
  require_file "${TOOLS_DIR}/inspect_ect.py"
  require_file "holder_keys/Martinez.jkt"

  printf '%s' "${ECT}" |
    python3 "${TOOLS_DIR}/inspect_ect.py" \
      --stdin \
      --expected-envelope-id "${ENVELOPE_ID}" \
      --expected-jkt-file "holder_keys/Martinez.jkt" \
      --require-tissue mucus \
      --require-tissue normal_colon_mucosa \
      --require-tissue lymphocytes \
      --forbid-tissue debris
 
fi

pass "Direct /mint_ect compiled and signed an envelope-bound capability"

make_dpop() {
  local private_hex="$1"
  local public_b64="$2"
  local nonce="$3"
  local jti="$4"
  local proof_envelope="$5"

  python3 "${TOOLS_DIR}/make_dpop_jwt_eddsa.py" \
    "${private_hex}" \
    "${public_b64}" \
    "${nonce}" \
    "${jti}" \
    "POST" \
    "${DPOP_HTU}" \
    "${proof_envelope}"
}

run_probe() {
  local test_name="$1"
  local expected_allow="$2"
  local expected_reason="$3"
  local request_envelope="$4"
  local proof_envelope="$5"
  local tissues_json="$6"
  local private_hex="$7"
  local public_b64="$8"


  local nonce
  local jti
  local dpop
  local request_body
  local response
  local actual_allow
  local actual_reason

  nonce="nonce-$(date +%s%N)"
  jti="jti-$(date +%s%N)"

  dpop="$(
    make_dpop \
      "${private_hex}" \
      "${public_b64}" \
      "${nonce}" \
      "${jti}" \
      "${proof_envelope}"
  )"

  request_body="$(
    jq -nc \
      --arg envelope "${request_envelope}" \
      --arg run "${RUN_ID}" \
      --arg jti "${jti}" \
      --argjson tissues "${tissues_json}" \
      '{
        envelope_id: $envelope,
        run_id: $run,
        resource: "pathmnist-colon-pathology",
        action: "query_model",
        purpose: "approved_model_query",
        requested_tissues: $tissues,
        jti: $jti
      }'
  )"

  printf '\n-- %s --\n' "${test_name}"
  printf '%s\n' "${request_body}" | jq .

  response="$(
    curl "${CURL_HUB[@]}" \
      -X POST "${VERIFIER_URL}/admission/check" \
      -H "Authorization: ECT ${ECT}" \
      -H "DPoP: ${dpop}" \
      -H "X-DPoP-Nonce: ${nonce}" \
      -H 'content-type: application/json' \
      -d "${request_body}"
  )"

  printf '%s\n' "${response}" | jq .

  actual_allow="$(printf '%s' "${response}" | jq -r '.allow')"
  actual_reason="$(printf '%s' "${response}" | jq -r '.reason // ""')"

  [[ "${actual_allow}" == "${expected_allow}" ]] || fail \
    "${test_name}: expected allow=${expected_allow}, got allow=${actual_allow}"

  if [[ -n "${expected_reason}" ]]; then
    [[ "${actual_reason}" == "${expected_reason}" ]] || fail \
      "${test_name}: expected reason=${expected_reason}, got reason=${actual_reason}"
  fi

  pass "${test_name}"
}

section "4. Admission decisions"

run_probe \
  "UC-01 allowed other-tissue request" \
  "true" \
  "" \
  "${ENVELOPE_ID}" \
  "${ENVELOPE_ID}" \
  '["mucus","normal_colon_mucosa","lymphocytes"]' \
  "${PRIV_HEX}" \
  "${PUB_B64}"

run_probe \
  "UC-02 reserved background request" \
  "false" \
  "reserved_tissue" \
  "${ENVELOPE_ID}" \
  "${ENVELOPE_ID}" \
  '["background"]' \
  "${PRIV_HEX}" \
  "${PUB_B64}"

run_probe \
  "UC-03 cancer-associated scope exceeds capability" \
  "false" \
  "capability_scope_exceeded" \
  "${ENVELOPE_ID}" \
  "${ENVELOPE_ID}" \
  '[
    "cancer_associated_stroma",
    "colorectal_adenocarcinoma_epithelium"
  ]' \
  "${PRIV_HEX}" \
  "${PUB_B64}"

run_probe \
  "UC-04 cross-envelope reuse" \
  "false" \
  "envelope_mismatch" \
  "${OTHER_ENVELOPE_ID}" \
  "${OTHER_ENVELOPE_ID}" \
  '["mucus","lymphocytes"]' \
  "${PRIV_HEX}" \
  "${PUB_B64}"

run_probe \
  "UC-04b proof signed for another envelope" \
  "false" \
  "dpop_envelope_mismatch" \
  "${ENVELOPE_ID}" \
  "${OTHER_ENVELOPE_ID}" \
  '["mucus","lymphocytes"]' \
  "${PRIV_HEX}" \
  "${PUB_B64}"

section "5. Holder-binding mismatch"

python3 "${TOOLS_DIR}/gen_member_keys.py" \
  --org "org://HospitalA" \
  --who "intruder" \
  | sed 's/^/[intruder] /'

INTRUDER_PUB_B64="$(tr -d '\r\n' < holder_keys/intruder.pubb64)"
INTRUDER_PRIV_HEX="$(tr -d '\r\n' < holder_keys/intruder.privhex)"

run_probe \
  "UC-05 DPoP signed by a different holder" \
  "false" \
  "dpop_binding_mismatch" \
  "${ENVELOPE_ID}" \
  "${ENVELOPE_ID}" \
  '["mucus","lymphocytes"]' \
  "${INTRUDER_PRIV_HEX}" \
  "${INTRUDER_PUB_B64}"

printf '\n'
pass "Test2A passed: governance minting and admission checks are operational"
