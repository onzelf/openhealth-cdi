#!/usr/bin/env bash
# Test2D_issuer_owned_entitlements.sh
#
# Read-only Iteration 3 smoke test.
# It does not edit files, register members, or invoke OpenTofu.
#
# Usage:
#   ISSUER_IP=192.168.1.25 \
#     ./Test2D_issuer_owned_entitlements.sh <valid-envelope-id>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENVELOPE_ID="${1:-}"
ISSUER_IP="${ISSUER_IP:-192.168.1.25}"
ISSUER_PORT="${ISSUER_PORT:-9443}"

ACTORS="${SRC_DIR}/vfp-core/issuers/config/actors.json"
ENT_A="${SRC_DIR}/vfp-core/issuers/config/hospital_a_entitlements.json"
ENT_B="${SRC_DIR}/vfp-core/issuers/config/hospital_b_entitlements.json"
CAPS="${SRC_DIR}/vfp-core/issuers/config/cap_profiles.json"
ISSUER="${SRC_DIR}/vfp-core/issuers/issuer.py"
HUB="${SRC_DIR}/vfp-core/hub/hub.py"
GATEKEEPER="${SRC_DIR}/vfp-governance/gatekeeper/app.py"
MAIN_TF="${SRC_DIR}/infra/tofu/main.tf"
TEST3E="${SCRIPT_DIR}/Test3E_dashboard_policy_scope.sh"
CA="${SRC_DIR}/vfp-governance/verifier/certs/ca.crt"
A_CRT="${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.crt"
A_KEY="${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.key"
B_CRT="${SRC_DIR}/vfp-governance/verifier/certs/HospitalB-admin.crt"
B_KEY="${SRC_DIR}/vfp-governance/verifier/certs/HospitalB-admin.key"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

pass() { printf '\033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }
section() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

[[ -n "${ENVELOPE_ID}" ]] || fail "Usage: $0 <valid-envelope-id>"
for cmd in curl jq python3 grep awk; do
  command -v "${cmd}" >/dev/null 2>&1 || fail "Missing command: ${cmd}"
done
for file in "${ACTORS}" "${ENT_A}" "${ENT_B}" "${CAPS}" "${ISSUER}" \
  "${HUB}" "${GATEKEEPER}" "${MAIN_TF}" "${TEST3E}" "${CA}" \
  "${A_CRT}" "${A_KEY}" "${B_CRT}" "${B_KEY}"; do
  [[ -s "${file}" ]] || fail "Missing or empty file: ${file}"
done

request() {
  local host="$1" cert="$2" key="$3" data="$4" out="$5"
  curl -sS \
    --resolve "${host}:${ISSUER_PORT}:${ISSUER_IP}" \
    --cacert "${CA}" --cert "${cert}" --key "${key}" \
    -o "${out}" -w '%{http_code}' \
    -H 'content-type: application/json' \
    -d "${data}" \
    "https://${host}:${ISSUER_PORT}/mint"
}

decode() {
  python3 - "$1" >"$2" <<'PY'
import base64, json, sys
p = sys.argv[1].split(".")
if len(p) != 3:
    raise SystemExit("not_compact_jws")
s = p[1] + "=" * (-len(p[1]) % 4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(s)), indent=2))
PY
}

mint() {
  local host="$1" cert="$2" key="$3" sub="$4" out="$5" status
  status="$(request "${host}" "${cert}" "${key}" \
    "$(jq -nc --arg s "${sub}" --arg e "${ENVELOPE_ID}" \
      '{sub:$s,envelope_id:$e}')" "${out}")"
  [[ "${status}" == "200" ]] || {
    jq . "${out}" >&2 || true
    fail "Mint for ${sub} returned HTTP ${status}"
  }
}

has_query_tissue() {
  jq -e --arg t "$2" \
    '[.cap[]? | select(.action == "query_model") | .scope.pathology_labels[]?] | index($t) != null' "$1" >/dev/null
}

lacks_query_tissue() {
  jq -e --arg t "$2" \
    '[.cap[]? | select(.action == "query_model") | .scope.pathology_labels[]?] | index($t) == null' "$1" >/dev/null
}

section "1. Hub cannot select an authorization profile"

HUB_MINT="$(awk '
  /^def mint_principal_ect\(/ {on=1}
  on && /^def / && !/^def mint_principal_ect\(/ {exit}
  on {print}
' "${HUB}")"

grep -q '"sub"' <<<"${HUB_MINT}" || fail "Hub mint request has no subject"
grep -q '"envelope_id"' <<<"${HUB_MINT}" || fail "Hub mint request has no envelope"
! grep -q '"profile"' <<<"${HUB_MINT}" || fail "Hub still sends a profile"

FORGED="${TMP}/forged.json"
STATUS="$(request issuer-hospitala.local "${A_CRT}" "${A_KEY}" \
  "$(jq -nc --arg e "${ENVELOPE_ID}" \
    '{sub:"Audrey",profile:"PATHMNIST_CANCER_ASSOCIATED_READER",envelope_id:$e}')" \
  "${FORGED}")"
[[ "${STATUS}" == "422" ]] || fail "Profile injection returned HTTP ${STATUS}"
jq -e '.detail[] | select((.loc[-1] // "") == "profile")' \
  "${FORGED}" >/dev/null || fail "Issuer did not reject the profile field"
pass "Hub sends no profile and issuer rejects profile injection"

section "2. Audrey receives issuer-owned source and derivative entitlements"

jq -e '.members.Audrey == [
  "PATHMNIST_OTHER_TISSUE_READER",
  "PATHMNIST_DERIVATIVE_READER"
]' "${ENT_A}" >/dev/null \
  || fail "Unexpected Audrey entitlement assignment"
jq -e '."org://HospitalA".PATHMNIST_OTHER_TISSUE_READER == "capset:pathmnist_other_tissue_reader"
  and ."org://HospitalA".PATHMNIST_DERIVATIVE_READER == "capset:pathmnist_derivative_reader"' \
  "${CAPS}" >/dev/null || fail "Unexpected Audrey capset mapping"

mint issuer-hospitala.local "${A_CRT}" "${A_KEY}" Audrey "${TMP}/audrey.json"
decode "$(jq -r '.ect' "${TMP}/audrey.json")" "${TMP}/audrey-claims.json"
for tissue in mucus normal_colon_mucosa lymphocytes; do
  has_query_tissue "${TMP}/audrey-claims.json" "${tissue}" \
    || fail "Audrey ECT is missing ${tissue}"
done
for tissue in background cancer_associated_stroma \
  colorectal_adenocarcinoma_epithelium debris; do
  lacks_query_tissue "${TMP}/audrey-claims.json" "${tissue}" \
    || fail "Audrey ECT unexpectedly contains ${tissue}"
done
jq -e '[.cap[]? | select(
  .resource == "pathmnist-derived-representation"
  and .action == "consume_derivative"
  and .purpose == "approved_derivative_consumption"
)] | length == 1' "${TMP}/audrey-claims.json" >/dev/null \
  || fail "Audrey ECT is missing derivative-consumption authority"
pass "Audrey keeps other-tissue source query and gains derivative consumption only"

section "3. Bob receives only his issuer-owned entitlement"

B_PROFILE="$(jq -r '.members.Bob // empty' "${ENT_B}")"
B_CAPSET="$(jq -r --arg p "${B_PROFILE}" \
  '."org://HospitalB"[$p] // empty' "${CAPS}")"
[[ "${B_PROFILE}" == "PATHMNIST_CANCER_ASSOCIATED_READER" ]] \
  || fail "Unexpected Bob entitlement: ${B_PROFILE:-missing}"
[[ "${B_CAPSET}" == "capset:pathmnist_cancer_associated_reader" ]] \
  || fail "Unexpected Bob capset: ${B_CAPSET:-missing}"

mint issuer-hospitalb.local "${B_CRT}" "${B_KEY}" Bob "${TMP}/bob.json"
decode "$(jq -r '.ect' "${TMP}/bob.json")" "${TMP}/bob-claims.json"
for tissue in cancer_associated_stroma colorectal_adenocarcinoma_epithelium; do
  has_query_tissue "${TMP}/bob-claims.json" "${tissue}" \
    || fail "Bob ECT is missing ${tissue}"
done
for tissue in background mucus normal_colon_mucosa lymphocytes debris; do
  lacks_query_tissue "${TMP}/bob-claims.json" "${tissue}" \
    || fail "Bob ECT unexpectedly contains ${tissue}"
done
pass "Bob receives only the cancer-associated capability"

section "4. An unknown principal cannot mint"

UNKNOWN="Test2D-Unknown-$(date +%s)"
UNKNOWN_OUT="${TMP}/unknown.json"
STATUS="$(request issuer-hospitala.local "${A_CRT}" "${A_KEY}" \
  "$(jq -nc --arg s "${UNKNOWN}" --arg e "${ENVELOPE_ID}" \
    '{sub:$s,envelope_id:$e}')" "${UNKNOWN_OUT}")"
[[ "${STATUS}" == "404" ]] || fail "Unknown subject returned HTTP ${STATUS}"
jq -e --arg s "${UNKNOWN}" '.detail == ("unknown_sub:" + $s)' \
  "${UNKNOWN_OUT}" >/dev/null || fail "Incorrect unknown-subject denial"
pass "Unknown principals cannot mint"

section "5. actors.json has no authorization path"

jq -e '[.. | objects | select(
  has("default_profile") or has("available_operations")
  or has("profile") or has("capset")
)] | length == 0' "${ACTORS}" >/dev/null \
  || fail "actors.json contains authorization fields"
! grep -qE 'actors\.json|ACTOR_CATALOG' "${ISSUER}" \
  || fail "Issuer reads the actor catalogue"
ISSUER_TF="$(awk '
  /resource "docker_container" "issuer_hospitala"/ {on=1}
  /# Hub \(coordination orchestrator\)/ {on=0}
  on {print}
' "${MAIN_TF}")"
! grep -q 'actors.json' <<<"${ISSUER_TF}" \
  || fail "Issuer infrastructure mounts actors.json"
grep -q 'hospital_a_entitlements.json' <<<"${ISSUER_TF}" \
  || fail "Hospital A entitlement mount is missing"
grep -q 'hospital_b_entitlements.json' <<<"${ISSUER_TF}" \
  || fail "Hospital B entitlement mount is missing"
pass "Actor scenario metadata is disconnected from authorization"

section "6. Issuer assignments determine the minted capability"

jq -e --slurpfile a "${TMP}/audrey-claims.json" \
  '.cap != $a[0].cap' "${TMP}/bob-claims.json" >/dev/null \
  || fail "Distinct issuer assignments produced identical ECT capabilities"
pass "Distinct issuer-owned assignments produce distinct ECT capabilities"

section "7. Gatekeeper compilation and governed inference remain unchanged"

! grep -qE 'actors\.json|member_entitlements|default_profile' "${GATEKEEPER}" \
  || fail "Gatekeeper acquired an actor-entitlement dependency"
A_HASH="$(jq -r '.policy.policy_hash // empty' "${TMP}/audrey-claims.json")"
B_HASH="$(jq -r '.policy.policy_hash // empty' "${TMP}/bob-claims.json")"
[[ -n "${A_HASH}" && "${A_HASH}" == "${B_HASH}" ]] \
  || fail "Audrey and Bob ECTs do not share the Gatekeeper policy hash"
"${TEST3E}" "${ENVELOPE_ID}"
pass "Gatekeeper policy compilation and dashboard admission remain authoritative"

printf '\n'
pass "Test2D passed: all seven issuer-owned entitlement requirements are validated"
