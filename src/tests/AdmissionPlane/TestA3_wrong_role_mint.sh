#!/usr/bin/env bash
set -uo pipefail

# TestA3_wrong_role_mint.sh
#
# Hypothesis:
#   Even when Audrey supplies a valid holder proof, a Hub certificate must NOT
#   be sufficient to exercise Hospital A issuer authority and cause the issuer
#   to mint authority for a Hospital A human member.
#
# Result meanings:
#   VULNERABILITY CONFIRMED  Hub identity + valid Audrey holder proof obtained
#                            Audrey/Hospital A ECT.
#   ASSUMPTION REJECTED      Hospital A edge rejected Hub identity.
#   INCONCLUSIVE             Setup/control failed or another response occurred.
#
# Usage:
#   ./TestA3_wrong_role_mint.sh <active-envelope-id>

ENVELOPE_ID="${1:-}"
[[ -n "${ENVELOPE_ID}" ]] || {
  echo "Usage: $0 <active-envelope-id>" >&2
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ISSUER_HOST="${ISSUER_HOST:-issuer-hospitala.local}"
ISSUER_PORT="${ISSUER_PORT:-9443}"
ISSUER_IP="${ISSUER_IP:-127.0.0.1}"
ISSUER_URL="https://${ISSUER_HOST}:${ISSUER_PORT}/mint"
MINT_PROOF_HTU="${MINT_PROOF_HTU:-urn:openhealth:issuer:mint}"

CA="${SRC_DIR}/vfp-governance/verifier/certs/ca.crt"
A_CRT="${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.crt"
A_KEY="${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.key"
HUB_CRT="${SRC_DIR}/vfp-governance/verifier/certs/hub.crt"
HUB_KEY="${SRC_DIR}/vfp-governance/verifier/certs/hub.key"

SUBJECT="${SUBJECT:-Audrey}"
HOLDER_PRIVATE="${HOLDER_PRIVATE:-${SRC_DIR}/../secrets/holder_keys/${SUBJECT}.privhex}"
GEN_MEMBER_KEYS="${SRC_DIR}/tools/gen_member_keys.py"
MAKE_DPOP="${SRC_DIR}/tools/make_dpop_jwt_eddsa.py"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail_setup() {
  printf '\n? INCONCLUSIVE: %s\n' "$*" >&2
  exit 2
}

for cmd in curl jq python3; do
  command -v "${cmd}" >/dev/null 2>&1 || fail_setup "missing command ${cmd}"
done
for f in "${CA}" "${A_CRT}" "${A_KEY}" "${HUB_CRT}" "${HUB_KEY}" "${HOLDER_PRIVATE}" "${GEN_MEMBER_KEYS}" "${MAKE_DPOP}"; do
  [[ -s "${f}" ]] || fail_setup "missing file ${f}"
done

HOLDER_IDENTITY="$(
  python3 "${GEN_MEMBER_KEYS}" \
    --derive \
    --private-key "${HOLDER_PRIVATE}" \
    --format json
)" || fail_setup "unable to derive ${SUBJECT} holder identity"

HOLDER_PUB_B64="$(jq -er '.pub_b64' <<<"${HOLDER_IDENTITY}")" || \
  fail_setup "unable to derive ${SUBJECT} public key"
HOLDER_PRIV_HEX="$(tr -d '\r\n' <"${HOLDER_PRIVATE}")"

request() {
  local cert="$1" key="$2" outfile="$3"
  local nonce jti holder_dpop body

  nonce="mint-nonce-$(date +%s%N)"
  jti="mint-jti-$(date +%s%N)"

  holder_dpop="$(
    python3 "${MAKE_DPOP}" \
      "${HOLDER_PRIV_HEX}" \
      "${HOLDER_PUB_B64}" \
      "${nonce}" \
      "${jti}" \
      POST \
      "${MINT_PROOF_HTU}" \
      "${ENVELOPE_ID}"
  )" || fail_setup "unable to create ${SUBJECT} holder mint proof"

  body="$(
    jq -nc \
      --arg sub "${SUBJECT}" \
      --arg e "${ENVELOPE_ID}" \
      --arg dpop "${holder_dpop}" \
      '{sub:$sub,envelope_id:$e,holder_dpop:$dpop}'
  )"

  curl -sS \
    --resolve "${ISSUER_HOST}:${ISSUER_PORT}:${ISSUER_IP}" \
    --cacert "${CA}" \
    --cert "${cert}" \
    --key "${key}" \
    -o "${outfile}" \
    -w '%{http_code}' \
    -H 'content-type: application/json' \
    -d "${body}" \
    "${ISSUER_URL}"
}

echo "== Control: Hospital A admin + Audrey holder proof -> Hospital A issuer =="
CONTROL_STATUS="$(request "${A_CRT}" "${A_KEY}" "${TMP}/control.json")" || \
  fail_setup "control TLS/request failed"

[[ "${CONTROL_STATUS}" == "200" ]] || \
  fail_setup "Hospital A control mint returned HTTP ${CONTROL_STATUS}"
[[ -n "$(jq -r '.ect // empty' "${TMP}/control.json")" ]] || \
  fail_setup "control mint returned no ECT"

echo "✓ Control mint succeeded"

echo
echo "== Attack: Hub certificate + Audrey holder proof -> Hospital A issuer -> Audrey =="

ATTACK_STATUS="$(request "${HUB_CRT}" "${HUB_KEY}" "${TMP}/attack.json")"
RC=$?
if [[ ${RC} -ne 0 ]]; then
  echo
  echo "✓ ASSUMPTION REJECTED: Hub certificate could not traverse Hospital A issuer edge"
  exit 0
fi

cat "${TMP}/attack.json" | jq . 2>/dev/null || true

if [[ "${ATTACK_STATUS}" == "401" || "${ATTACK_STATUS}" == "403" ]]; then
  echo
  echo "✓ ASSUMPTION REJECTED: Hospital A issuer rejected Hub identity"
  exit 0
fi

if [[ "${ATTACK_STATUS}" != "200" ]]; then
  fail_setup "Hub request returned HTTP ${ATTACK_STATUS}"
fi

ATTACK_ECT="$(jq -r '.ect // empty' "${TMP}/attack.json")"
[[ -n "${ATTACK_ECT}" ]] || fail_setup "HTTP 200 returned without ECT"

CLAIMS="$(
python3 - "${ATTACK_ECT}" <<'PY'
import base64, json, sys
p = sys.argv[1].split(".")
if len(p) != 3:
    raise SystemExit(2)
s = p[1] + "=" * (-len(p[1]) % 4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(s))))
PY
)" || fail_setup "returned ECT is not a decodable compact JWS"

printf '%s\n' "${CLAIMS}" | jq '{sub,org_iss,envelope_id,actor_type,cap_profiles}'

if printf '%s\n' "${CLAIMS}" | jq -e \
  --arg e "${ENVELOPE_ID}" \
  '.sub=="Audrey" and .org_iss=="org://HospitalA" and .envelope_id==$e' \
  >/dev/null; then
  echo
  echo "✗ VULNERABILITY CONFIRMED: Hub identity + valid Audrey holder proof caused Hospital A to mint Audrey authority"
  exit 1
fi

fail_setup "mint succeeded but returned claims do not establish Audrey/Hospital A authority"
