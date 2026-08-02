#!/usr/bin/env bash
# Test2F_issuer_registration_boundary.sh
#
# FFix #3 minimal conformance check.
# Verifies that:
#   - Hospital A member registration is restricted to Hospital A admin CN
#   - an existing sub cannot be silently overwritten
#   - failed registration attempts do not mutate the enrolled identity

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ISSUER_HOST="${ISSUER_HOST:-issuer-hospitala.local}"
ISSUER_PORT="${ISSUER_PORT:-9443}"
ISSUER_IP="${ISSUER_IP:-}"
ISSUER_URL="https://${ISSUER_HOST}:${ISSUER_PORT}"

ORG_ID="${ORG_ID:-org://HospitalA}"
SUBJECT="${SUBJECT:-Audrey}"
GEN_MEMBER_KEYS="${SRC_DIR}/tools/gen_member_keys.py"

CAC="${SRC_DIR}/vfp-governance/verifier/certs/ca.crt"
ADMIN_CRT="${ADMIN_CRT:-${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.crt}"
ADMIN_KEY="${ADMIN_KEY:-${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.key}"
FOREIGN_CRT="${FOREIGN_CRT:-${SRC_DIR}/vfp-governance/verifier/certs/HospitalB-admin.crt}"
FOREIGN_KEY="${FOREIGN_KEY:-${SRC_DIR}/vfp-governance/verifier/certs/HospitalB-admin.key}"

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
  [[ -s "$1" ]] || fail "Missing or empty file: $1"
}

for cmd in curl jq python3; do
  command -v "${cmd}" >/dev/null 2>&1 || fail "Missing command: ${cmd}"
done

for path in \
  "${CAC}" \
  "${ADMIN_CRT}" \
  "${ADMIN_KEY}" \
  "${FOREIGN_CRT}" \
  "${FOREIGN_KEY}" \
  "${GEN_MEMBER_KEYS}"; do
  require_file "${path}"
done

CURL_ADMIN=(
  -sS
  --cacert "${CAC}"
  --cert "${ADMIN_CRT}"
  --key "${ADMIN_KEY}"
)

CURL_FOREIGN=(
  -sS
  --cacert "${CAC}"
  --cert "${FOREIGN_CRT}"
  --key "${FOREIGN_KEY}"
)

if [[ -n "${ISSUER_IP}" ]]; then
  CURL_ADMIN+=(--resolve "${ISSUER_HOST}:${ISSUER_PORT}:${ISSUER_IP}")
  CURL_FOREIGN+=(--resolve "${ISSUER_HOST}:${ISSUER_PORT}:${ISSUER_IP}")
fi

section "1. Verify issuer and existing enrollment"

RIGHTS_FILE="${TMP_DIR}/rights.json"
RIGHTS_STATUS="$(
  curl "${CURL_ADMIN[@]}" \
    -o "${RIGHTS_FILE}" \
    -w '%{http_code}' \
    "${ISSUER_URL}/rights"
)"

[[ "${RIGHTS_STATUS}" == "200" ]] || {
  cat "${RIGHTS_FILE}" >&2
  fail "Issuer /rights returned HTTP ${RIGHTS_STATUS}"
}

jq -e --arg org "${ORG_ID}" '.org == $org' "${RIGHTS_FILE}" >/dev/null ||
  fail "Issuer route does not resolve to ${ORG_ID}"

MEMBERS_FILE="${TMP_DIR}/members.json"
MEMBERS_STATUS="$(
  curl "${CURL_ADMIN[@]}" \
    -o "${MEMBERS_FILE}" \
    -w '%{http_code}' \
    "${ISSUER_URL}/members"
)"

[[ "${MEMBERS_STATUS}" == "200" ]] || {
  cat "${MEMBERS_FILE}" >&2
  fail "Issuer /members returned HTTP ${MEMBERS_STATUS}"
}

MEMBER_COUNT="$(
  jq -r --arg sub "${SUBJECT}" \
    '[.members[] | select(.sub == $sub)] | length' \
    "${MEMBERS_FILE}"
)"
[[ "${MEMBER_COUNT}" == "1" ]] ||
  fail "Issuer registry contains ${MEMBER_COUNT} records for ${SUBJECT}, expected 1"

MEMBER_ID="$(jq -er --arg sub "${SUBJECT}" '.members[] | select(.sub == $sub) | .member_id' "${MEMBERS_FILE}")"
ORIGINAL_PUB="$(jq -er --arg sub "${SUBJECT}" '.members[] | select(.sub == $sub) | .pub_b64' "${MEMBERS_FILE}")"
ORIGINAL_JKT="$(jq -er --arg sub "${SUBJECT}" '.members[] | select(.sub == $sub) | .jkt' "${MEMBERS_FILE}")"

pass "Existing ${SUBJECT} enrollment is present under ${ORG_ID}"

section "2. Accept fresh registration by Hospital A admin"

PROBE_SUB="conformance-probe-$(date +%s)-${RANDOM}"
python3 "${GEN_MEMBER_KEYS}" \
  --org "${ORG_ID}" \
  --who "${PROBE_SUB}" \
  --output-dir "${TMP_DIR}" \
  >/dev/null

PROBE_REQUEST="$(jq 'del(.created_at)' "${TMP_DIR}/${PROBE_SUB}.register.json")"
PROBE_PUB="$(tr -d '\r\n' < "${TMP_DIR}/${PROBE_SUB}.pubb64")"
PROBE_JKT="$(tr -d '\r\n' < "${TMP_DIR}/${PROBE_SUB}.jkt")"

PROBE_FILE="${TMP_DIR}/probe-register.json"
PROBE_STATUS="$(
  curl "${CURL_ADMIN[@]}" \
    -o "${PROBE_FILE}" \
    -w '%{http_code}' \
    -X POST \
    "${ISSUER_URL}/members/register" \
    -H 'content-type: application/json' \
    -d "${PROBE_REQUEST}"
)"

[[ "${PROBE_STATUS}" == "200" ]] || {
  cat "${PROBE_FILE}" >&2
  fail "Fresh admin registration should return HTTP 200, got ${PROBE_STATUS}"
}

PROBE_MEMBERS_FILE="${TMP_DIR}/members-probe.json"
curl "${CURL_ADMIN[@]}" \
  -o "${PROBE_MEMBERS_FILE}" \
  "${ISSUER_URL}/members"

jq -e \
  --arg sub "${PROBE_SUB}" \
  --arg pub "${PROBE_PUB}" \
  --arg jkt "${PROBE_JKT}" \
  '
    [.members[] | select(
      .sub == $sub
      and .pub_b64 == $pub
      and .jkt == $jkt
    )] | length == 1
  ' \
  "${PROBE_MEMBERS_FILE}" >/dev/null ||
  fail "Fresh admin registration is absent or does not match generated holder identity"

pass "Hospital A admin can register a fresh holder identity"

section "3. Reject silent overwrite of existing sub"

REPLACEMENT_REQUEST="$(
  jq -nc \
    --arg org "${ORG_ID}" \
    --arg member_id "${MEMBER_ID}" \
    --arg sub "${SUBJECT}" \
    '{
      org_id: $org,
      member_id: $member_id,
      sub: $sub,
      pub_b64: "forged-public-key",
      jkt: "forged-thumbprint"
    }'
)"

DUPLICATE_FILE="${TMP_DIR}/duplicate.json"
DUPLICATE_STATUS="$(
  curl "${CURL_ADMIN[@]}" \
    -o "${DUPLICATE_FILE}" \
    -w '%{http_code}' \
    -X POST \
    "${ISSUER_URL}/members/register" \
    -H 'content-type: application/json' \
    -d "${REPLACEMENT_REQUEST}"
)"

cat "${DUPLICATE_FILE}" | jq .

[[ "${DUPLICATE_STATUS}" == "409" ]] ||
  fail "Existing sub overwrite should return HTTP 409, got ${DUPLICATE_STATUS}"

jq -e \
  --arg detail "sub_already_registered:${SUBJECT}" \
  '.detail == $detail' \
  "${DUPLICATE_FILE}" >/dev/null ||
  fail "Issuer did not return the expected duplicate-sub rejection"

pass "Silent overwrite of ${SUBJECT} is rejected"

section "4. Reject registration by another organization's admin"

FOREIGN_FILE="${TMP_DIR}/foreign.json"
FOREIGN_STATUS="$(
  curl "${CURL_FOREIGN[@]}" \
    -o "${FOREIGN_FILE}" \
    -w '%{http_code}' \
    -X POST \
    "${ISSUER_URL}/members/register" \
    -H 'content-type: application/json' \
    -d "${REPLACEMENT_REQUEST}"
)"

[[ "${FOREIGN_STATUS}" == "403" ]] || {
  cat "${FOREIGN_FILE}" >&2
  fail "Foreign admin registration should return HTTP 403, got ${FOREIGN_STATUS}"
}

pass "Hospital B admin cannot register members through Hospital A issuer"

section "5. Verify existing enrollment was not mutated"

AFTER_FILE="${TMP_DIR}/members-after.json"
AFTER_STATUS="$(
  curl "${CURL_ADMIN[@]}" \
    -o "${AFTER_FILE}" \
    -w '%{http_code}' \
    "${ISSUER_URL}/members"
)"

[[ "${AFTER_STATUS}" == "200" ]] || {
  cat "${AFTER_FILE}" >&2
  fail "Issuer /members returned HTTP ${AFTER_STATUS} after negative tests"
}

jq -e \
  --arg sub "${SUBJECT}" \
  --arg pub "${ORIGINAL_PUB}" \
  --arg jkt "${ORIGINAL_JKT}" \
  '
    [.members[] | select(
      .sub == $sub
      and .pub_b64 == $pub
      and .jkt == $jkt
    )] | length == 1
  ' \
  "${AFTER_FILE}" >/dev/null ||
  fail "${SUBJECT} enrollment changed after rejected registration attempts"

pass "Existing holder identity remains unchanged"

printf '\n'
pass "Test2F passed: issuer registration accepts the authorized admin, rejects foreign admins, and prevents overwrite"
