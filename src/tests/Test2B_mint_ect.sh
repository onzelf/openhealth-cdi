#!/usr/bin/env bash
# Test2B_mint_ect.sh
#
# ECT mint-contract smoke test.
#
# Direct path under test:
#   policy.json capset
#       -> POST /mint_ect
#       -> inspect_ect.py
#
# This test does not call /admission/check and does not call issuer.py.
#
# Usage:
#   ./Test2B_mint_ect.sh <active-envelope-id>
#
# Optional environment overrides:
#   VERIFIER_URL=https://verifier.local:8443
#   CAP_PROFILE=capset:pathmnist_other_tissue_reader
#   MINT_CRT=...
#   MINT_KEY=...

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOLS_DIR="${SRC_DIR}/tools"

VERIFIER_URL="${VERIFIER_URL:-https://verifier.local:8443}"
CAP_PROFILE="${CAP_PROFILE:-capset:pathmnist_other_tissue_reader}"

POLICY_JSON="${SRC_DIR}/vfp-governance/verifier/state/policy.json"
INSPECT_ECT="${TOOLS_DIR}/inspect_ect.py"

CAC="${SRC_DIR}/vfp-governance/verifier/certs/ca.crt"
HUB_CRT="${SRC_DIR}/vfp-governance/verifier/certs/hub.crt"
HUB_KEY="${SRC_DIR}/vfp-governance/verifier/certs/hub.key"

MINT_CRT="${MINT_CRT:-${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.crt}"
MINT_KEY="${MINT_KEY:-${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.key}"

ENVELOPE_ID="${1:-}"
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
  "${INSPECT_ECT}" \
  "${CAC}" \
  "${HUB_CRT}" \
  "${HUB_KEY}" \
  "${MINT_CRT}" \
  "${MINT_KEY}" \
  "${TOOLS_DIR}/gen_member_keys.py"; do
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

section "0. Validate minting profile"

jq -e . "${POLICY_JSON}" >/dev/null \
  || fail "policy.json is invalid JSON"

jq -e \
  --arg profile "${CAP_PROFILE}" \
  '.cap_profiles[$profile].cap | type == "array" and length > 0' \
  "${POLICY_JSON}" >/dev/null \
  || fail "Missing or empty capset: ${CAP_PROFILE}"

pass "Minting capset exists in policy.json"

section "1. Check gatekeeper and active envelope"

HEALTH="$(
  curl "${CURL_HUB[@]}" \
    "${VERIFIER_URL}/health"
)"
printf '%s\n' "${HEALTH}" | jq .

printf '%s\n' "${HEALTH}" | jq -e '.ok == true' >/dev/null \
  || fail "Gatekeeper health check failed"

HEALTH_POLICY_HASH="$(
  printf '%s\n' "${HEALTH}" | jq -r '.policy_hash // empty'
)"
[[ -n "${HEALTH_POLICY_HASH}" ]] || fail \
  "Gatekeeper health response has no policy_hash"

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

pass "Gatekeeper is healthy and envelope is ACTIVE"

section "2. Generate holder key"

cd "${SCRIPT_DIR}"

python3 "${TOOLS_DIR}/gen_member_keys.py" \
  --org "org://HospitalA" \
  --who "Martinez" \
  | sed 's/^/[Martinez] /'

PUB_B64="$(tr -d '\r\n' < holder_keys/Martinez.pubb64)"
[[ -n "${PUB_B64}" ]] || fail "Missing Martinez public key"

pass "Holder public key generated"

section "3. Call /mint_ect"

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

ECT="$(printf '%s\n' "${MINT_RESPONSE}" | jq -r '.ect_jws // empty')"
MINT_POLICY_HASH="$(
  printf '%s\n' "${MINT_RESPONSE}" | jq -r '.policy_hash // empty'
)"

[[ -n "${ECT}" ]] || fail "/mint_ect did not return ect_jws"
[[ "${MINT_POLICY_HASH}" == "${HEALTH_POLICY_HASH}" ]] || fail \
  "Mint response policy_hash differs from the active gatekeeper policy_hash"

pass "/mint_ect returned an ECT under the active policy"

section "4. Inspect ECT minting contract"

printf '%s' "${ECT}" |
  python3 "${INSPECT_ECT}" \
    --stdin \
    --expected-envelope-id "${ENVELOPE_ID}" \
    --expected-resource "pathmnist-colon-pathology" \
    --expected-action "query_model" \
    --expected-purpose "approved_model_query" \
    --require-tissue "mucus" \
    --require-tissue "normal_colon_mucosa" \
    --require-tissue "lymphocytes" \
    --forbid-tissue "debris"

pass "Test2B passed: /mint_ect produced the expected PathMNIST ECT"
