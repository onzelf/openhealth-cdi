#!/usr/bin/env bash
# Test2C_issuer_mint.sh
#
# Issuer-side smoke test only.
#
# Path under test:
#   issuer cap_profiles.json alias
#       -> holder registry lookup
#       -> POST issuer /mint
#       -> issuer forwards envelope_id to gatekeeper /mint_ect
#       -> issuer returns ECT
#       -> inspect_ect.py verifies the returned capability
#
# This test does not call /mint_ect directly and does not call
# /admission/check. Those belong to Test2B and Test2A respectively.
#
# Usage:
#   ./Test2C_issuer_mint.sh <valid-envelope-id>
#
# Optional environment overrides:
#   ISSUER_HOST=issuer-hospitala.local
#   ISSUER_PORT=9443
#   ISSUER_IP=192.168.1.25
#   ORG_ID=org://HospitalA
#   PROFILE_NAME=PATHMNIST_OTHER_TISSUE_READER
#   EXPECTED_CAPSET=capset:pathmnist_other_tissue_reader
#   SUBJECT=Martinez-Test2C
#
# If issuer-hospitala.local already resolves correctly, ISSUER_IP is not
# required. Otherwise set ISSUER_IP to the host address bound by OpenTofu.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOLS_DIR="${SRC_DIR}/tools"

ISSUER_HOST="${ISSUER_HOST:-issuer-hospitala.local}"
ISSUER_PORT="${ISSUER_PORT:-9443}"
ISSUER_IP="${ISSUER_IP:-}"
ISSUER_URL="https://${ISSUER_HOST}:${ISSUER_PORT}"

ORG_ID="${ORG_ID:-org://HospitalA}"
PROFILE_NAME="${PROFILE_NAME:-PATHMNIST_OTHER_TISSUE_READER}"
EXPECTED_CAPSET="${EXPECTED_CAPSET:-capset:pathmnist_other_tissue_reader}"
SUBJECT="${SUBJECT:-Martinez-Test2C-$(date +%s)}"

ENVELOPE_ID="${1:-}"

CAP_PROFILES_JSON="${SRC_DIR}/vfp-core/issuers/config/cap_profiles.json"
INSPECT_ECT="${TOOLS_DIR}/inspect_ect.py"

CAC="${SRC_DIR}/vfp-governance/verifier/certs/ca.crt"
CLIENT_CRT="${CLIENT_CRT:-${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.crt}"
CLIENT_KEY="${CLIENT_KEY:-${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.key}"

NBF="$(date -u -Iseconds -d '-60 seconds' | sed 's/+00:00/Z/')"
EXP="$(date -u -Iseconds -d '+5 minutes' | sed 's/+00:00/Z/')"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

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
  "Usage: $0 <valid-envelope-id>"

for cmd in curl jq python3; do
  require_command "${cmd}"
done

for path in \
  "${CAP_PROFILES_JSON}" \
  "${INSPECT_ECT}" \
  "${TOOLS_DIR}/gen_member_keys.py" \
  "${CAC}" \
  "${CLIENT_CRT}" \
  "${CLIENT_KEY}"; do
  require_file "${path}"
done

CURL_ISSUER=(
  -sS
  --cacert "${CAC}"
  --cert "${CLIENT_CRT}"
  --key "${CLIENT_KEY}"
)

if [[ -n "${ISSUER_IP}" ]]; then
  CURL_ISSUER+=(
    --resolve "${ISSUER_HOST}:${ISSUER_PORT}:${ISSUER_IP}"
  )
fi

issuer_request() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local output_file="$4"
  local status

  if [[ -n "${data}" ]]; then
    status="$(
      curl "${CURL_ISSUER[@]}" \
        -o "${output_file}" \
        -w '%{http_code}' \
        -X "${method}" \
        "${ISSUER_URL}${path}" \
        -H 'content-type: application/json' \
        -d "${data}"
    )"
  else
    status="$(
      curl "${CURL_ISSUER[@]}" \
        -o "${output_file}" \
        -w '%{http_code}' \
        -X "${method}" \
        "${ISSUER_URL}${path}"
    )"
  fi

  printf '%s' "${status}"
}

section "0. Validate issuer profile mapping"

jq -e . "${CAP_PROFILES_JSON}" >/dev/null \
  || fail "cap_profiles.json is invalid JSON"

ACTUAL_CAPSET="$(
  jq -r \
    --arg org "${ORG_ID}" \
    --arg profile "${PROFILE_NAME}" \
    '.[$org][$profile] // empty' \
    "${CAP_PROFILES_JSON}"
)"

[[ "${ACTUAL_CAPSET}" == "${EXPECTED_CAPSET}" ]] || fail \
  "${ORG_ID}/${PROFILE_NAME} maps to '${ACTUAL_CAPSET}', expected '${EXPECTED_CAPSET}'"

pass "Issuer alias maps to ${EXPECTED_CAPSET}"

section "1. Check issuer /rights"

RIGHTS_FILE="${TMP_DIR}/rights.json"
RIGHTS_STATUS="$(
  issuer_request GET /rights "" "${RIGHTS_FILE}"
)"

cat "${RIGHTS_FILE}" | jq .

[[ "${RIGHTS_STATUS}" == "200" ]] || fail \
  "Issuer /rights returned HTTP ${RIGHTS_STATUS}"

jq -e \
  --arg org "${ORG_ID}" \
  --arg profile "${PROFILE_NAME}" \
  '
    .org == $org
    and (.profiles | index($profile) != null)
  ' \
  "${RIGHTS_FILE}" >/dev/null \
  || fail "Issuer did not load ${PROFILE_NAME} for ${ORG_ID}"

pass "Issuer is running with the expected profile configuration"

section "2. Generate and register a unique holder"

cd "${SCRIPT_DIR}"

python3 "${TOOLS_DIR}/gen_member_keys.py" \
  --org "${ORG_ID}" \
  --who "${SUBJECT}" \
  >/dev/null

REGISTER_SOURCE="holder_keys/${SUBJECT}.register.json"
require_file "${REGISTER_SOURCE}"

REGISTER_REQUEST="$(
  jq -c \
    '{
      org_id,
      member_id,
      sub,
      pub_b64,
      jkt
    }' \
    "${REGISTER_SOURCE}"
)"

REGISTER_FILE="${TMP_DIR}/register.json"
REGISTER_STATUS="$(
  issuer_request POST /members/register "${REGISTER_REQUEST}" "${REGISTER_FILE}"
)"

cat "${REGISTER_FILE}" | jq .

[[ "${REGISTER_STATUS}" == "200" ]] || fail \
  "Holder registration returned HTTP ${REGISTER_STATUS}"

jq -e \
  --arg sub "${SUBJECT}" \
  '.status == "ok" and .sub == $sub' \
  "${REGISTER_FILE}" >/dev/null \
  || fail "Issuer did not confirm holder registration"

MEMBERS_FILE="${TMP_DIR}/members.json"
MEMBERS_STATUS="$(
  issuer_request GET /members "" "${MEMBERS_FILE}"
)"

[[ "${MEMBERS_STATUS}" == "200" ]] || fail \
  "Issuer /members returned HTTP ${MEMBERS_STATUS}"

jq -e \
  --arg sub "${SUBJECT}" \
  '.members[] | select(.sub == $sub)' \
  "${MEMBERS_FILE}" >/dev/null \
  || fail "Registered holder cannot be resolved from the issuer registry"

pass "Issuer registry resolves ${SUBJECT}"

section "3. Mint through issuer /mint"

MINT_REQUEST="$(
  jq -nc \
    --arg sub "${SUBJECT}" \
    --arg profile "${PROFILE_NAME}" \
    --arg envelope "${ENVELOPE_ID}" \
    --arg nbf "${NBF}" \
    --arg exp "${EXP}" \
    '{
      sub: $sub,
      profile: $profile,
      envelope_id: $envelope,
      nbf: $nbf,
      exp: $exp
    }'
)"

printf '%s\n' "${MINT_REQUEST}" | jq .

MINT_FILE="${TMP_DIR}/mint.json"
MINT_STATUS="$(
  issuer_request POST /mint "${MINT_REQUEST}" "${MINT_FILE}"
)"

cat "${MINT_FILE}" | jq .

[[ "${MINT_STATUS}" == "200" ]] || fail \
  "Issuer /mint returned HTTP ${MINT_STATUS}"

ECT="$(jq -r '.ect // empty' "${MINT_FILE}")"
[[ -n "${ECT}" ]] || fail "Issuer /mint did not return an ECT"

pass "Issuer resolved the holder and returned an ECT"

section "4. Verify profile resolution and envelope_id propagation"

printf '%s' "${ECT}" |
  python3 "${INSPECT_ECT}" \
    --stdin \
    --expected-envelope-id "${ENVELOPE_ID}" \
    --expected-resource "pathmnist-colon-pathology" \
    --expected-action "query_model" \
    --expected-purpose "approved_model_query" \
    --require-tissue "background" \
    --require-tissue "lymphocytes" \
    --forbid-tissue "debris"

pass "Issuer forwarded envelope_id and selected the expected policy capset"

section "5. Reject an unknown issuer profile"

UNKNOWN_PROFILE="PATHMNIST_PROFILE_NOT_ALLOWED"

BAD_PROFILE_REQUEST="$(
  jq -nc \
    --arg sub "${SUBJECT}" \
    --arg profile "${UNKNOWN_PROFILE}" \
    --arg envelope "${ENVELOPE_ID}" \
    '{
      sub: $sub,
      profile: $profile,
      envelope_id: $envelope
    }'
)"

BAD_PROFILE_FILE="${TMP_DIR}/bad-profile.json"
BAD_PROFILE_STATUS="$(
  issuer_request POST /mint "${BAD_PROFILE_REQUEST}" "${BAD_PROFILE_FILE}"
)"

cat "${BAD_PROFILE_FILE}" | jq .

[[ "${BAD_PROFILE_STATUS}" == "403" ]] || fail \
  "Unknown profile should return HTTP 403, got ${BAD_PROFILE_STATUS}"

jq -e \
  --arg profile "${UNKNOWN_PROFILE}" \
  '.detail == ("profile_not_allowed:" + $profile)' \
  "${BAD_PROFILE_FILE}" >/dev/null \
  || fail "Unknown profile denial reason is incorrect"

pass "Issuer rejects a profile absent from its organization-scoped mapping"

printf '\n'
pass "Test2C passed: issuer profile resolution, registry lookup, envelope forwarding, and minting are operational"
