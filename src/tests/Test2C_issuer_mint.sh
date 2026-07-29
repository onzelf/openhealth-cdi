#!/usr/bin/env bash
# Test2C_issuer_mint.sh
#
# Issuer-side mint smoke test.
#
# Path under test:
#   issuer member registry lookup
#       -> issuer-owned member entitlement resolution
#       -> issuer cap_profiles.json alias
#       -> POST Gatekeeper /mint_ect
#       -> issuer returns ECT
#
# Usage:
#   ./Test2C_issuer_mint.sh <valid-envelope-id>

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
SUBJECT="${SUBJECT:-Audrey}"
ENVELOPE_ID="${1:-}"

CAP_PROFILES_JSON="${SRC_DIR}/vfp-core/issuers/config/cap_profiles.json"
ENTITLEMENTS_JSON="${ENTITLEMENTS_JSON:-${SRC_DIR}/vfp-core/issuers/config/hospital_a_entitlements.json}"
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

[[ -n "${ENVELOPE_ID}" ]] || fail "Usage: $0 <valid-envelope-id>"

for cmd in curl jq python3; do
  require_command "${cmd}"
done

for path in \
  "${CAP_PROFILES_JSON}" \
  "${ENTITLEMENTS_JSON}" \
  "${INSPECT_ECT}" \
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
  CURL_ISSUER+=(--resolve "${ISSUER_HOST}:${ISSUER_PORT}:${ISSUER_IP}")
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

section "0. Validate issuer-owned entitlement"

PROFILE_FROM_ENTITLEMENT="$(
  jq -r \
    --arg org "${ORG_ID}" \
    --arg sub "${SUBJECT}" \
    'select(.org == $org) | .members[$sub] // empty' \
    "${ENTITLEMENTS_JSON}"
)"

[[ "${PROFILE_FROM_ENTITLEMENT}" == "${PROFILE_NAME}" ]] || fail \
  "${ORG_ID}/${SUBJECT} is assigned '${PROFILE_FROM_ENTITLEMENT}', expected '${PROFILE_NAME}'"

ACTUAL_CAPSET="$(
  jq -r \
    --arg org "${ORG_ID}" \
    --arg profile "${PROFILE_NAME}" \
    '.[$org][$profile] // empty' \
    "${CAP_PROFILES_JSON}"
)"

[[ "${ACTUAL_CAPSET}" == "${EXPECTED_CAPSET}" ]] || fail \
  "${ORG_ID}/${PROFILE_NAME} maps to '${ACTUAL_CAPSET}', expected '${EXPECTED_CAPSET}'"

pass "Issuer owns ${SUBJECT} -> ${PROFILE_NAME} -> ${EXPECTED_CAPSET}"

section "1. Verify holder enrollment"

MEMBERS_FILE="${TMP_DIR}/members.json"
MEMBERS_STATUS="$(issuer_request GET /members "" "${MEMBERS_FILE}")"
cat "${MEMBERS_FILE}" | jq .

[[ "${MEMBERS_STATUS}" == "200" ]] || fail \
  "Issuer /members returned HTTP ${MEMBERS_STATUS}"

jq -e \
  --arg sub "${SUBJECT}" \
  '.members[] | select(.sub == $sub)' \
  "${MEMBERS_FILE}" >/dev/null \
  || fail "${SUBJECT} is not enrolled with ${ORG_ID}"

pass "Issuer registry resolves ${SUBJECT}"

section "2. Mint without a caller-selected profile"

MINT_REQUEST="$(
  jq -nc \
    --arg sub "${SUBJECT}" \
    --arg envelope "${ENVELOPE_ID}" \
    --arg nbf "${NBF}" \
    --arg exp "${EXP}" \
    '{
      sub: $sub,
      envelope_id: $envelope,
      nbf: $nbf,
      exp: $exp
    }'
)"

MINT_FILE="${TMP_DIR}/mint.json"
MINT_STATUS="$(issuer_request POST /mint "${MINT_REQUEST}" "${MINT_FILE}")"
cat "${MINT_FILE}" | jq .

[[ "${MINT_STATUS}" == "200" ]] || fail \
  "Issuer /mint returned HTTP ${MINT_STATUS}"

ECT="$(jq -r '.ect // empty' "${MINT_FILE}")"
[[ -n "${ECT}" ]] || fail "Issuer /mint did not return an ECT"

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
    --forbid-tissue "background" \
    --forbid-tissue "debris"

pass "Issuer resolved the assigned profile and returned the expected ECT"

section "3. Reject caller-selected authorization"

FORGED_REQUEST="$(
  jq -nc \
    --arg sub "${SUBJECT}" \
    --arg envelope "${ENVELOPE_ID}" \
    '{
      sub: $sub,
      profile: "PATHMNIST_CANCER_ASSOCIATED_READER",
      envelope_id: $envelope
    }'
)"

FORGED_FILE="${TMP_DIR}/forged.json"
FORGED_STATUS="$(issuer_request POST /mint "${FORGED_REQUEST}" "${FORGED_FILE}")"
cat "${FORGED_FILE}" | jq .

[[ "${FORGED_STATUS}" == "422" ]] || fail \
  "Caller-supplied profile should return HTTP 422, got ${FORGED_STATUS}"

jq -e '
  .detail[]
  | select((.loc[-1] // "") == "profile")
' "${FORGED_FILE}" >/dev/null \
  || fail "Issuer did not identify profile as a forbidden request field"

pass "Issuer rejects caller-selected authorization"

printf '\n'
pass "Test2C passed: issuer-owned entitlement minting is operational"
