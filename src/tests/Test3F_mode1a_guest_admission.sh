#!/usr/bin/env bash
# Test3F_mode1a_guest_admission.sh
#
# Gate 3A — sponsored guest activation without Flower C.
#
# Proves:
#   1. Charlie is an active Mode 1A guest actor associated with Hospital C.
#   2. Hospital A owns Charlie's guest-contributor entitlement.
#   3. Charlie has one holder identity enrolled with Hospital A.
#   4. The real Hub administration path can mint Charlie's ECT.
#   5. The ECT grants submit_update / federated_training only.
#   6. Charlie cannot use that ECT to query the trained model.
#
# Usage:
#   ./Test3F_mode1a_guest_admission.sh <active-envelope-id>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENVELOPE_ID="${1:-}"
RUN_ID="${RUN_ID:-local-pathmnist-ab-001}"
HUB_URL="${HUB_URL:-http://127.0.0.1:8080}"

ISSUER_HOST="${ISSUER_HOST:-issuer-hospitala.local}"
ISSUER_PORT="${ISSUER_PORT:-9443}"
ISSUER_IP="${ISSUER_IP:-192.168.1.25}"
ISSUER_URL="https://${ISSUER_HOST}:${ISSUER_PORT}"

ORG_ID="org://HospitalA"
SUBJECT="Charlie"
PROFILE_NAME="PATHMNIST_GUEST_CONTRIBUTOR"
EXPECTED_CAPSET="capset:pathmnist_guest_contributor"
EXPECTED_GUEST_INSTITUTION="org://HospitalC"

ACTORS_JSON="${SRC_DIR}/vfp-core/issuers/config/actors.json"
ENTITLEMENTS_JSON="${SRC_DIR}/vfp-core/issuers/config/hospital_a_entitlements.json"
CAP_PROFILES_JSON="${SRC_DIR}/vfp-core/issuers/config/cap_profiles.json"
POLICY_JSON="${SRC_DIR}/vfp-governance/verifier/state/policy.json"

GEN_MEMBER_KEYS="${SRC_DIR}/tools/gen_member_keys.py"
INSPECT_ECT="${SRC_DIR}/tools/inspect_ect.py"

HOLDER_KEYS_DIR="${SRC_DIR}/vfp-governance/verifier/vault/holder_keys"
HOLDER_PRIVATE="${HOLDER_KEYS_DIR}/${SUBJECT}.privhex"

CAC="${SRC_DIR}/vfp-governance/verifier/certs/ca.crt"
CLIENT_CRT="${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.crt"
CLIENT_KEY="${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.key"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

pass() { printf '\033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }
section() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
require_file() { [[ -s "$1" ]] || fail "Missing or empty file: $1"; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"; }

[[ -n "${ENVELOPE_ID}" ]] || fail "Usage: $0 <active-envelope-id>"

for command_name in curl jq python3; do
  require_command "${command_name}"
done

for path in \
  "${ACTORS_JSON}" \
  "${ENTITLEMENTS_JSON}" \
  "${CAP_PROFILES_JSON}" \
  "${POLICY_JSON}" \
  "${GEN_MEMBER_KEYS}" \
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
  --resolve "${ISSUER_HOST}:${ISSUER_PORT}:${ISSUER_IP}"
)

issuer_request() {
  local method="$1"
  local path="$2"
  local output_file="$3"
  local data="${4:-}"
  local status

  if [[ -n "${data}" ]]; then
    status="$(
      curl "${CURL_ISSUER[@]}" \
        -o "${output_file}" \
        -w '%{http_code}' \
        -X "${method}" \
        -H 'content-type: application/json' \
        -d "${data}" \
        "${ISSUER_URL}${path}"
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

hub_request() {
  local method="$1"
  local path="$2"
  local output_file="$3"
  local data="${4:-}"
  local status

  if [[ -n "${data}" ]]; then
    status="$(
      curl -sS \
        -o "${output_file}" \
        -w '%{http_code}' \
        -X "${method}" \
        -H 'content-type: application/json' \
        -d "${data}" \
        "${HUB_URL}${path}"
    )"
  else
    status="$(
      curl -sS \
        -o "${output_file}" \
        -w '%{http_code}' \
        -X "${method}" \
        "${HUB_URL}${path}"
    )"
  fi

  printf '%s' "${status}"
}

section "0. Verify the pre-declared guest participation grade"

jq -e \
  --arg sub "${SUBJECT}" \
  --arg guest_org "${EXPECTED_GUEST_INSTITUTION}" \
  '
    ."org://HospitalA"[]
    | select(.principal == $sub)
    | .actor_type == "human"
      and .status == "active"
      and (.modes | index("mode1a")) != null
      and .participation_grade == "guest_contributor"
      and .guest_institution == $guest_org
  ' "${ACTORS_JSON}" >/dev/null \
  || fail "Charlie is not an active Hospital A sponsored Mode 1A guest"

ENTITLEMENT_PROFILE="$(
  jq -r --arg sub "${SUBJECT}" '.members[$sub] // empty' "${ENTITLEMENTS_JSON}"
)"
[[ "${ENTITLEMENT_PROFILE}" == "${PROFILE_NAME}" ]] \
  || fail "Charlie entitlement is '${ENTITLEMENT_PROFILE}', expected '${PROFILE_NAME}'"

GUEST_INSTITUTION="$(
  jq -r --arg sub "${SUBJECT}" '.guest_institutions[$sub] // empty' "${ENTITLEMENTS_JSON}"
)"
[[ "${GUEST_INSTITUTION}" == "${EXPECTED_GUEST_INSTITUTION}" ]] \
  || fail "Charlie guest institution is '${GUEST_INSTITUTION}', expected '${EXPECTED_GUEST_INSTITUTION}'"

MAPPED_CAPSET="$(
  jq -r \
    --arg org "${ORG_ID}" \
    --arg profile "${PROFILE_NAME}" \
    '.[$org][$profile] // empty' \
    "${CAP_PROFILES_JSON}"
)"
[[ "${MAPPED_CAPSET}" == "${EXPECTED_CAPSET}" ]] \
  || fail "${PROFILE_NAME} maps to '${MAPPED_CAPSET}', expected '${EXPECTED_CAPSET}'"

jq -e \
  --arg capset "${EXPECTED_CAPSET}" \
  '
    .cap_profiles[$capset].cap == ["submit_update_guest_contributor"]
    and .ops.submit_update_guest_contributor.action == "submit_update"
    and .ops.submit_update_guest_contributor.purpose == "federated_training"
    and (
      .ops.submit_update_guest_contributor.scope.pathology_labels
      | index("background")
    ) == null
  ' "${POLICY_JSON}" >/dev/null \
  || fail "Guest-contributor policy profile is not the expected bounded training capability"

pass "A+B pre-declared Charlie's guest participation grade under Hospital A sponsorship"

section "1. Provision or verify Charlie's holder identity"

mkdir -p "${HOLDER_KEYS_DIR}"

if [[ ! -s "${HOLDER_PRIVATE}" ]]; then
  python3 "${GEN_MEMBER_KEYS}" \
    --org "${ORG_ID}" \
    --who "${SUBJECT}" \
    --output-dir "${HOLDER_KEYS_DIR}" \
    >"${TMP_DIR}/generate-holder.txt"
  pass "Generated Charlie's canonical holder key"
fi

HOLDER_IDENTITY="$(
  python3 "${GEN_MEMBER_KEYS}" \
    --derive \
    --private-key "${HOLDER_PRIVATE}" \
    --format json
)" || fail "Unable to derive Charlie holder identity"

HOLDER_PUB_B64="$(jq -er '.pub_b64' <<<"${HOLDER_IDENTITY}")"
HOLDER_JKT="$(jq -er '.jkt' <<<"${HOLDER_IDENTITY}")"
printf '%s' "${HOLDER_JKT}" >"${TMP_DIR}/Charlie.jkt"

MEMBERS_FILE="${TMP_DIR}/members.json"
MEMBERS_STATUS="$(issuer_request GET /members "${MEMBERS_FILE}")"
[[ "${MEMBERS_STATUS}" == "200" ]] || {
  cat "${MEMBERS_FILE}" >&2
  fail "Issuer /members returned HTTP ${MEMBERS_STATUS}"
}

CHARLIE_COUNT="$(
  jq -r \
    --arg sub "${SUBJECT}" \
    '[.members[] | select(.sub == $sub)] | length' \
    "${MEMBERS_FILE}"
)"

if [[ "${CHARLIE_COUNT}" == "0" ]]; then
  REGISTER_REQUEST="$(
    jq -nc \
      --arg org "${ORG_ID}" \
      --arg sub "${SUBJECT}" \
      --arg pub "${HOLDER_PUB_B64}" \
      --arg jkt "${HOLDER_JKT}" \
      '{
        org_id: $org,
        member_id: $sub,
        sub: $sub,
        pub_b64: $pub,
        jkt: $jkt
      }'
  )"

  REGISTER_FILE="${TMP_DIR}/register.json"
  REGISTER_STATUS="$(
    issuer_request POST /members/register "${REGISTER_FILE}" "${REGISTER_REQUEST}"
  )"
  [[ "${REGISTER_STATUS}" == "200" ]] || {
    cat "${REGISTER_FILE}" >&2
    fail "Charlie registration returned HTTP ${REGISTER_STATUS}"
  }
  pass "Registered Charlie with Hospital A issuer"
elif [[ "${CHARLIE_COUNT}" == "1" ]]; then
  ENROLLED_PUB="$(
    jq -er \
      --arg sub "${SUBJECT}" \
      '.members[] | select(.sub == $sub) | .pub_b64' \
      "${MEMBERS_FILE}"
  )"
  ENROLLED_JKT="$(
    jq -er \
      --arg sub "${SUBJECT}" \
      '.members[] | select(.sub == $sub) | .jkt' \
      "${MEMBERS_FILE}"
  )"

  [[ "${ENROLLED_PUB}" == "${HOLDER_PUB_B64}" ]] \
    || fail "Existing Charlie enrollment does not match the canonical holder key"
  [[ "${ENROLLED_JKT}" == "${HOLDER_JKT}" ]] \
    || fail "Existing Charlie enrollment has a different JKT"
  pass "Existing Charlie enrollment matches canonical holder custody"
else
  fail "Hospital A issuer contains ${CHARLIE_COUNT} Charlie records"
fi

section "2. Select E2 and exercise the Hub mint path"

SELECT_FILE="${TMP_DIR}/select.json"
SELECT_STATUS="$(hub_request POST "/administration/envelopes/${ENVELOPE_ID}/select" "${SELECT_FILE}")"
[[ "${SELECT_STATUS}" == "200" ]] || {
  cat "${SELECT_FILE}" >&2
  fail "Hub envelope selection returned HTTP ${SELECT_STATUS}"
}

jq -e \
  --arg envelope "${ENVELOPE_ID}" \
  '.selected_envelope_id == $envelope' \
  "${SELECT_FILE}" >/dev/null \
  || fail "Hub did not select the requested envelope"

HUB_MINT_REQUEST="$(
  jq -nc --arg envelope "${ENVELOPE_ID}" '{envelope_id: $envelope}'
)"
HUB_MINT_FILE="${TMP_DIR}/hub-mint.json"
HUB_MINT_STATUS="$(
  hub_request \
    POST \
    "/administration/holders/${SUBJECT}/mint-ect" \
    "${HUB_MINT_FILE}" \
    "${HUB_MINT_REQUEST}"
)"
[[ "${HUB_MINT_STATUS}" == "200" ]] || {
  cat "${HUB_MINT_FILE}" >&2
  fail "Hub Charlie mint returned HTTP ${HUB_MINT_STATUS}"
}

jq -e \
  --arg sub "${SUBJECT}" \
  --arg envelope "${ENVELOPE_ID}" \
  '
    .principal == $sub
    and .envelope_id == $envelope
    and .ready == true
    and (.expires_at | type) == "number"
  ' "${HUB_MINT_FILE}" >/dev/null \
  || fail "Hub did not store a ready Charlie ECT"

pass "Charlie is operationally mintable through the Hub administration path"

section "3. Inspect Charlie's issuer-owned guest ECT"

DIRECT_MINT_REQUEST="$(
  jq -nc \
    --arg sub "${SUBJECT}" \
    --arg envelope "${ENVELOPE_ID}" \
    '{sub: $sub, envelope_id: $envelope}'
)"
DIRECT_MINT_FILE="${TMP_DIR}/direct-mint.json"
DIRECT_MINT_STATUS="$(
  issuer_request POST /mint "${DIRECT_MINT_FILE}" "${DIRECT_MINT_REQUEST}"
)"
[[ "${DIRECT_MINT_STATUS}" == "200" ]] || {
  cat "${DIRECT_MINT_FILE}" >&2
  fail "Direct issuer mint returned HTTP ${DIRECT_MINT_STATUS}"
}

ECT="$(jq -r '.ect // empty' "${DIRECT_MINT_FILE}")"
[[ -n "${ECT}" ]] || fail "Hospital A issuer did not return Charlie's ECT"

printf '%s' "${ECT}" |
  python3 "${INSPECT_ECT}" \
    --stdin \
    --expected-envelope-id "${ENVELOPE_ID}" \
    --expected-jkt-file "${TMP_DIR}/Charlie.jkt" \
    --expected-resource "pathmnist-colon-pathology" \
    --expected-action "submit_update" \
    --expected-purpose "federated_training" \
    --require-tissue "adipose" \
    --require-tissue "debris" \
    --require-tissue "lymphocytes" \
    --require-tissue "mucus" \
    --require-tissue "smooth_muscle" \
    --require-tissue "normal_colon_mucosa" \
    --require-tissue "cancer_associated_stroma" \
    --require-tissue "colorectal_adenocarcinoma_epithelium" \
    --forbid-tissue "background" \
    >"${TMP_DIR}/ect-inspection.json"

cat "${TMP_DIR}/ect-inspection.json" | jq .

CLAIMS_FILE="${TMP_DIR}/claims.json"
python3 - "${ECT}" "${CLAIMS_FILE}" <<'PY'
import base64
import json
import sys

token, output = sys.argv[1], sys.argv[2]
parts = token.split(".")
if len(parts) != 3:
    raise SystemExit("ECT is not a compact JWS")
payload = parts[1] + "=" * ((4 - len(parts[1]) % 4) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload).decode("utf-8"))
with open(output, "w", encoding="utf-8") as stream:
    json.dump(claims, stream, indent=2, sort_keys=True)
PY

jq -e \
  --arg sub "${SUBJECT}" \
  --arg org "${ORG_ID}" \
  --arg capset "${EXPECTED_CAPSET}" \
  '
    .sub == $sub
    and .actor_type == "human"
    and .org_iss == $org
    and (.cap_profiles | index($capset)) != null
    and ([.cap[] | select(.action == "query_model")] | length) == 0
  ' "${CLAIMS_FILE}" >/dev/null \
  || fail "Charlie ECT identity/profile is not the expected guest-contributor authorization"

pass "Charlie ECT grants bounded training contribution and no model-query authority"

section "4. Prove contribution does not imply model consumption"

INFERENCE_REQUEST="$(
  jq -nc \
    --arg principal "${SUBJECT}" \
    --arg envelope "${ENVELOPE_ID}" \
    --arg run "${RUN_ID}" \
    '{
      principal: $principal,
      envelope_id: $envelope,
      run_id: $run,
      requested_tissue: "lymphocytes",
      topk: 3
    }'
)"

INFERENCE_FILE="${TMP_DIR}/charlie-query.json"
INFERENCE_STATUS="$(
  hub_request POST /user/inference "${INFERENCE_FILE}" "${INFERENCE_REQUEST}"
)"
[[ "${INFERENCE_STATUS}" == "200" ]] || {
  cat "${INFERENCE_FILE}" >&2
  fail "Charlie governed query returned HTTP ${INFERENCE_STATUS}"
}

cat "${INFERENCE_FILE}" | jq .

jq -e \
  --arg sub "${SUBJECT}" \
  '
    .principal == $sub
    and .admission.allow == false
    and .admission.reason == "capability_violation"
    and .executed == false
  ' "${INFERENCE_FILE}" >/dev/null \
  || fail "Charlie query did not return the expected capability_violation DENY"

pass "Charlie query_model is DENIED while the backend remains unexecuted"

printf '\n'
pass "Gate 3A passed: Charlie is a sponsored guest contributor without model-consumption rights"
