#!/usr/bin/env bash
set -euo pipefail

# Gate 5C — Hal holder binding and capability admission.
# Usage: ./Test5C_agent_credential_admission.sh <active-envelope-id>

ENVELOPE_ID="${1:-}"
[[ -n "${ENVELOPE_ID}" ]] || { echo "Usage: $0 <active-envelope-id>" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ISSUER_IP="${ISSUER_IP:-192.168.1.25}"
ISSUER_PORT="${ISSUER_PORT:-9443}"
VERIFIER_IP="${VERIFIER_IP:-192.168.1.25}"
VERIFIER_PORT="${VERIFIER_PORT:-8443}"
RUN_ID="${RUN_ID:-local-pathmnist-ab-001}"
HAL_CONTAINER="${HAL_CONTAINER:-hal}"
DPOP_HTU="https://verifier.local/admission/check"

CA="${SRC_DIR}/vfp-governance/verifier/certs/ca.crt"
A_CRT="${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.crt"
A_KEY="${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.key"
HUB_CRT="${SRC_DIR}/vfp-governance/verifier/certs/hub.crt"
HUB_KEY="${SRC_DIR}/vfp-governance/verifier/certs/hub.key"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

pass() { printf '\033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }
section() { printf '\n============================================================\n%s\n============================================================\n' "$1"; }

for cmd in curl jq python3 docker; do command -v "${cmd}" >/dev/null || fail "Missing command: ${cmd}"; done
for f in "${CA}" "${A_CRT}" "${A_KEY}" "${HUB_CRT}" "${HUB_KEY}"; do [[ -s "${f}" ]] || fail "Missing file: ${f}"; done

issuer_curl() {
  curl -sS --resolve "issuer-hospitala.local:${ISSUER_PORT}:${ISSUER_IP}" \
    --cacert "${CA}" --cert "${A_CRT}" --key "${A_KEY}" "$@"
}

verifier_curl() {
  curl -sS --resolve "verifier.local:${VERIFIER_PORT}:${VERIFIER_IP}" \
    --cacert "${CA}" --cert "${HUB_CRT}" --key "${HUB_KEY}" "$@"
}

decode_ect() {
  python3 - "$1" <<'PY'
import base64,json,sys
p=sys.argv[1].split('.')[1]; p += '='*((4-len(p)%4)%4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(p)), indent=2, sort_keys=True))
PY
}

hal_sign_dpop() {
  docker exec -i "${HAL_CONTAINER}" python - "$1" "$2" "${DPOP_HTU}" "${ENVELOPE_ID}" <<'PY'
import base64,json,sys,time
from pathlib import Path
from cryptography.hazmat.primitives import serialization
nonce,jti,htu,eid=sys.argv[1:5]
r=Path('/var/lib/hal/identity')
k=serialization.load_pem_private_key((r/'holder.key').read_bytes(),password=None)
jwk=json.loads((r/'holder.jwk').read_text())
b64=lambda b: base64.urlsafe_b64encode(b).rstrip(b'=').decode()
enc=lambda o: b64(json.dumps(o,sort_keys=True,separators=(',',':')).encode())
h=enc({'typ':'dpop+jwt','alg':'EdDSA','jwk':jwk})
p=enc({'htu':htu,'htm':'POST','iat':int(time.time()),'jti':jti,'nonce':nonce,'envelope_id':eid})
print(f'{h}.{p}.{b64(k.sign(f"{h}.{p}".encode()))}')
PY
}

admission() {
  local label="$1" action="$2" purpose="$3" expected="$4"
  local nonce="nonce-$(python3 -c 'import secrets;print(secrets.token_urlsafe(12))')"
  local jti="jti-$(python3 -c 'import secrets;print(secrets.token_urlsafe(12))')"
  local dpop response
  dpop="$(hal_sign_dpop "${nonce}" "${jti}")"
  response="$(verifier_curl \
    -H "Authorization: ECT ${ECT}" -H "DPoP: ${dpop}" -H "X-DPoP-Nonce: ${nonce}" \
    -H 'content-type: application/json' \
    -d "$(jq -nc --arg e "${ENVELOPE_ID}" --arg r "${RUN_ID}" --arg a "${action}" --arg p "${purpose}" --arg j "${jti}" \
      '{envelope_id:$e,run_id:$r,resource:"pathmnist-colon-pathology",action:$a,purpose:$p,requested_tissues:["cancer_associated_stroma"],jti:$j}')" \
    "https://verifier.local:${VERIFIER_PORT}/admission/check")"
  printf '%s\n' "${response}" | jq .
  if [[ "${expected}" == "ALLOW" ]]; then
    printf '%s' "${response}" | jq -e '.allow == true' >/dev/null || fail "${label}: expected ALLOW"
  else
    printf '%s' "${response}" | jq -e '.allow == false' >/dev/null || fail "${label}: expected DENY"
  fi
  pass "${label}: ${expected}"
}

section "1. Hal holder identity"
docker inspect "${HAL_CONTAINER}" >/dev/null 2>&1 || fail "Hal container is unavailable"
HAL_JWK="$(docker exec "${HAL_CONTAINER}" cat /var/lib/hal/identity/holder.jwk)"
HAL_JKT="$(docker exec "${HAL_CONTAINER}" cat /var/lib/hal/identity/holder.jkt | tr -d '\r\n')"
HAL_PUB="$(printf '%s' "${HAL_JWK}" | jq -r '.x // empty')"
[[ -n "${HAL_PUB}" && -n "${HAL_JKT}" ]] || fail "Hal public identity is incomplete"
pass "Hal public identity present; private key remains inside Hal"

section "2. Hospital A registration"
MEMBERS="$(issuer_curl "https://issuer-hospitala.local:${ISSUER_PORT}/members")"
EXISTING_JKT="$(printf '%s' "${MEMBERS}" | jq -r '.members[]? | select(.sub=="Hal") | .jkt' | head -n1)"
if [[ -z "${EXISTING_JKT}" ]]; then
  BODY="$(jq -nc --arg pub "${HAL_PUB}" --arg jkt "${HAL_JKT}" \
    '{org_id:"org://HospitalA",member_id:"hal-mode1b",sub:"Hal",pub_b64:$pub,jkt:$jkt}')"
  OUT="$(issuer_curl -H 'content-type: application/json' -d "${BODY}" \
    "https://issuer-hospitala.local:${ISSUER_PORT}/members/register")"
  printf '%s' "${OUT}" | jq -e '.status == "ok" and .sub == "Hal"' >/dev/null || fail "Hal registration failed"
else
  [[ "${EXISTING_JKT}" == "${HAL_JKT}" ]] || fail "Hal is registered with a different JKT"
fi
pass "Hospital A binds Hal to the Hal-owned JKT"

section "3. Hal bounded-agent ECT"
MINT="$(issuer_curl -H 'content-type: application/json' \
  -d "$(jq -nc --arg e "${ENVELOPE_ID}" '{sub:"Hal",envelope_id:$e}')" \
  "https://issuer-hospitala.local:${ISSUER_PORT}/mint")"
ECT="$(printf '%s' "${MINT}" | jq -r '.ect // empty')"
[[ -n "${ECT}" ]] || { printf '%s\n' "${MINT}" | jq . >&2; fail "Hal ECT mint failed"; }
decode_ect "${ECT}" >"${TMP}/claims.json"
jq -e --arg e "${ENVELOPE_ID}" --arg jkt "${HAL_JKT}" '
  .sub=="Hal" and .actor_type=="agent" and .org_iss=="org://HospitalA"
  and .envelope_id==$e and .cnf.jkt==$jkt
  and .sponsors==["org://HospitalA","org://HospitalB"]
  and .cap_profiles==["capset:pathmnist_bounded_agent"]
  and ([.cap[].action] | index("bounded_inference") != null)
  and ([.cap[].action] | index("rebind") != null)
  and ([.cap[].action] | index("query_model") == null)
  and ([.cap[].action] | index("submit_update") == null)
' "${TMP}/claims.json" >/dev/null || { cat "${TMP}/claims.json" >&2; fail "Hal ECT contract mismatch"; }
pass "ECT is holder-bound, envelope-bound, issuer-attested and A+B-sponsored"

section "4. Capability admission"
admission "bounded inference" "bounded_inference" "bounded_model_inference" "ALLOW"
admission "ordinary source query" "query_model" "approved_model_query" "DENY"
admission "training contribution" "submit_update" "federated_training" "DENY"

section "5. Gate 5C invariant"
printf '%-30s %s\n' "INVARIANT" "RESULT"
printf '%s\n' "------------------------------------------------------------"
printf '%-30s %s\n' "Hal holder binding" "own JKT"
printf '%-30s %s\n' "issuer" "org://HospitalA"
printf '%-30s %s\n' "sponsors" "HospitalA + HospitalB"
printf '%-30s %s\n' "actor_type" "agent metadata"
printf '%-30s %s\n' "bounded inference" "ALLOW"
printf '%-30s %s\n' "ordinary query" "DENY"
printf '%-30s %s\n' "training contribution" "DENY"
echo
pass "Test5C passed: Hal authority derives from the admitted capability relation"
