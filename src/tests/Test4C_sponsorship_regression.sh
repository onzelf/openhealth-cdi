#!/usr/bin/env bash
set -euo pipefail

# Test4C — sponsorship regression and compatibility
#
# Run only after Fix #2 is deployed and a new active envelope has been created
# under the sponsorship-aware policy.
#
# Usage:
#   ./Test4C_sponsorship_regression.sh <active-new-envelope-id>

ENVELOPE_ID="${1:-}"
[[ -n "${ENVELOPE_ID}" ]] || {
  printf 'Usage: %s <active-new-envelope-id>\n' "$0" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ISSUER_IP="${ISSUER_IP:-192.168.1.25}"
ISSUER_PORT="${ISSUER_PORT:-9443}"

POLICY_JSON="${SRC_DIR}/vfp-governance/verifier/state/policy.json"
ENT_A="${SRC_DIR}/vfp-core/issuers/config/hospital_a_entitlements.json"
DECISIONS_DIR="${SRC_DIR}/vfp-governance/verifier/state/events/decisions"

CA="${SRC_DIR}/vfp-governance/verifier/certs/ca.crt"
A_CRT="${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.crt"
A_KEY="${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.key"
B_CRT="${SRC_DIR}/vfp-governance/verifier/certs/HospitalB-admin.crt"
B_KEY="${SRC_DIR}/vfp-governance/verifier/certs/HospitalB-admin.key"

TEST3E="${SCRIPT_DIR}/Test3E_dashboard_policy_scope.sh"
TEST3F="${SCRIPT_DIR}/Test3F_mode1a_guest_admission.sh"
TEST3G="${SCRIPT_DIR}/Test3G_mode1a_guest_contribution_admission.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

pass() { printf '\033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }
section() {
  printf '\n============================================================\n'
  printf '%s\n' "$1"
  printf '============================================================\n'
}

for cmd in curl jq python3; do
  command -v "${cmd}" >/dev/null 2>&1 || fail "Missing command: ${cmd}"
done

for file in \
  "${POLICY_JSON}" "${ENT_A}" \
  "${CA}" "${A_CRT}" "${A_KEY}" "${B_CRT}" "${B_KEY}" \
  "${TEST3E}" "${TEST3F}" "${TEST3G}"; do
  [[ -s "${file}" ]] || fail "Missing or empty file: ${file}"
done

decode_ect() {
  local token="$1"
  python3 - "${token}" <<'PY'
import base64
import json
import sys

parts = sys.argv[1].split(".")
if len(parts) != 3:
    raise SystemExit("not_compact_jws")

payload = parts[1]
payload += "=" * ((4 - len(payload) % 4) % 4)
print(json.dumps(
    json.loads(base64.urlsafe_b64decode(payload).decode("utf-8")),
    indent=2,
    sort_keys=True,
))
PY
}

issuer_mint() {
  local host="$1"
  local cert="$2"
  local key="$3"
  local sub="$4"
  local output="$5"

  local status
  status="$(
    curl -sS \
      --resolve "${host}:${ISSUER_PORT}:${ISSUER_IP}" \
      --cacert "${CA}" \
      --cert "${cert}" \
      --key "${key}" \
      -o "${output}" \
      -w '%{http_code}' \
      -H 'content-type: application/json' \
      -d "$(
        jq -nc \
          --arg sub "${sub}" \
          --arg envelope "${ENVELOPE_ID}" \
          '{sub:$sub,envelope_id:$envelope}'
      )" \
      "https://${host}:${ISSUER_PORT}/mint"
  )"

  [[ "${status}" == "200" ]] || {
    cat "${output}" >&2 || true
    fail "Mint for ${sub} returned HTTP ${status}"
  }
}

section "1. Compiled sponsorship policy"

jq -e '
  .sponsorship_rules["capset:pathmnist_guest_contributor"] as $g
  | .sponsorship_rules["capset:pathmnist_bounded_agent"] as $a
  | ($g.required == true)
    and ($g.min_sponsors == 1)
    and ($g.max_sponsors == 1)
    and ($g.sponsor_type == "founding_member")
    and ($a.required == true)
    and ($a.min_sponsors == 2)
    and ($a.max_sponsors == 2)
    and ($a.sponsor_type == "founding_member")
    and (.sponsorship_authority.eligible_sponsor_organizations
         == ["org://HospitalA", "org://HospitalB"])
    and (.sponsorship_authority.require_active_envelope_participation == true)
    and (.sponsorship_rules["capset:pathmnist_other_tissue_reader"] == null)
    and (.sponsorship_rules["capset:pathmnist_cancer_associated_reader"] == null)
    and (.sponsorship_rules["capset:pathmnist_hospital_a_participant"] == null)
    and (.sponsorship_rules["capset:pathmnist_hospital_b_participant"] == null)
' "${POLICY_JSON}" >/dev/null \
  || fail "Compiled sponsorship policy does not match the Fix #2 contract"

pass "Founding-member sponsorship authority and unsponsored profiles are explicitly separated"

section "2. Issuer-owned Charlie sponsorship remains distinct from provenance"

jq -e '
  .sponsors.Charlie == ["org://HospitalA"]
  and .guest_institutions.Charlie == "org://HospitalC"
  and (.sponsors.Charlie | index("org://HospitalC")) == null
' "${ENT_A}" >/dev/null \
  || fail "Charlie sponsor/provenance assignments are incorrect"

pass "Hospital A sponsors Charlie; Hospital C remains provenance only"

section "3. Caller cannot inject a sponsor set"

INJECT_OUT="${TMP}/inject.json"
INJECT_STATUS="$(
  curl -sS \
    --resolve "issuer-hospitala.local:${ISSUER_PORT}:${ISSUER_IP}" \
    --cacert "${CA}" \
    --cert "${A_CRT}" \
    --key "${A_KEY}" \
    -o "${INJECT_OUT}" \
    -w '%{http_code}' \
    -H 'content-type: application/json' \
    -d "$(
      jq -nc \
        --arg envelope "${ENVELOPE_ID}" \
        '{
          sub:"Charlie",
          envelope_id:$envelope,
          sponsors:["org://HospitalB"]
        }'
    )" \
    "https://issuer-hospitala.local:${ISSUER_PORT}/mint"
)"

[[ "${INJECT_STATUS}" == "422" ]] || {
  cat "${INJECT_OUT}" >&2 || true
  fail "Caller sponsor injection returned HTTP ${INJECT_STATUS}, expected 422"
}

jq -e '
  .detail[]
  | select((.loc[-1] // "") == "sponsors")
' "${INJECT_OUT}" >/dev/null \
  || fail "Issuer did not reject caller-supplied sponsors"

pass "Sponsor assignment remains issuer-owned"

section "4. Ordinary member ECTs remain unsponsored"

issuer_mint issuer-hospitala.local "${A_CRT}" "${A_KEY}" Audrey "${TMP}/audrey.json"
issuer_mint issuer-hospitalb.local "${B_CRT}" "${B_KEY}" Bob "${TMP}/bob.json"

AUDREY_ECT="$(jq -r '.ect // empty' "${TMP}/audrey.json")"
BOB_ECT="$(jq -r '.ect // empty' "${TMP}/bob.json")"

[[ -n "${AUDREY_ECT}" && -n "${BOB_ECT}" ]] \
  || fail "Member ECT mint returned an empty token"

decode_ect "${AUDREY_ECT}" >"${TMP}/audrey-claims.json"
decode_ect "${BOB_ECT}" >"${TMP}/bob-claims.json"

jq -e '
  .org_iss == "org://HospitalA"
  and ((.sponsors // []) | length == 0)
' "${TMP}/audrey-claims.json" >/dev/null \
  || fail "Audrey acquired an undeclared sponsorship relation"

jq -e '
  .org_iss == "org://HospitalB"
  and ((.sponsors // []) | length == 0)
' "${TMP}/bob-claims.json" >/dev/null \
  || fail "Bob acquired an undeclared sponsorship relation"

pass "Member ECTs remain unsponsored and org_iss remains issuer identity"

section "5. Charlie ECT carries the explicit sponsor relation"

issuer_mint issuer-hospitala.local "${A_CRT}" "${A_KEY}" Charlie "${TMP}/charlie.json"

CHARLIE_ECT="$(jq -r '.ect // empty' "${TMP}/charlie.json")"
[[ -n "${CHARLIE_ECT}" ]] || fail "Charlie ECT is empty"

decode_ect "${CHARLIE_ECT}" >"${TMP}/charlie-claims.json"

jq -e '
  .sub == "Charlie"
  and .org_iss == "org://HospitalA"
  and .sponsors == ["org://HospitalA"]
  and (.cap_profiles | index("capset:pathmnist_guest_contributor")) != null
  and (.sponsors | index("org://HospitalC")) == null
' "${TMP}/charlie-claims.json" >/dev/null \
  || fail "Charlie ECT does not preserve issuer/sponsor/provenance separation"

pass "Charlie ECT explicitly binds sponsorship without overloading org_iss"

section "6. Existing governed paths remain GREEN"

"${TEST3E}" "${ENVELOPE_ID}"
"${TEST3F}" "${ENVELOPE_ID}"
"${TEST3G}" "${ENVELOPE_ID}"

pass "Member inference and Mode 1A guest paths survived Fix #2"

section "7. Signed guest-admission evidence preserves sponsors"

LATEST_RECORD="$(
  python3 - "${DECISIONS_DIR}" "${ENVELOPE_ID}" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
envelope = sys.argv[2]

matches = []
for path in root.glob("decision-*.json"):
    try:
        rec = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        continue
    if (
        rec.get("sub") == "Charlie"
        and rec.get("allow_or_deny") == "ALLOW"
        and rec.get("requested_action") == "submit_update"
        and rec.get("approved_research_collaboration") == envelope
    ):
        matches.append((path.stat().st_mtime_ns, path))

if not matches:
    raise SystemExit(1)

print(max(matches)[1])
PY
)" || fail "No signed Charlie ALLOW contribution evidence found"

jq -e '
  .sub == "Charlie"
  and .org_iss == "org://HospitalA"
  and .sponsors == ["org://HospitalA"]
  and (.cap_profiles | index("capset:pathmnist_guest_contributor")) != null
' "${LATEST_RECORD}" >/dev/null \
  || fail "Signed admission evidence does not preserve verified sponsorship"

printf 'Evidence record: %s\n' "${LATEST_RECORD}"
pass "Signed decision evidence preserves issuer and sponsor as distinct relations"

section "8. Fix #2 regression invariant"

printf '%-28s %s\n' "INVARIANT" "RESULT"
printf '%s\n' "------------------------------------------------------------"
printf '%-28s %s\n' "member sponsorship" "absent"
printf '%-28s %s\n' "Charlie sponsor" "org://HospitalA"
printf '%-28s %s\n' "Charlie provenance" "org://HospitalC"
printf '%-28s %s\n' "caller sponsor injection" "rejected"
printf '%-28s %s\n' "member governed path" "GREEN"
printf '%-28s %s\n' "guest governed path" "GREEN"
printf '%-28s %s\n' "signed sponsor evidence" "present"

echo
pass "Test4C passed: sponsorship is explicit without regressing existing governance paths"
