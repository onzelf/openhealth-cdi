#!/usr/bin/env bash
set -euo pipefail

# Test4A — DPoP replay protection
#
# Proves:
#   1. a fresh holder-bound DPoP proof is admitted;
#   2. replaying the exact same proof is denied with dpop_replay;
#   3. the same ECT remains usable with a fresh DPoP proof.
#
# Usage:
#   ./Test4A_dpop_replay_protection.sh <active-envelope-id>

ENVELOPE_ID="${1:-}"
RUN_ID="${RUN_ID:-local-pathmnist-ab-001}"

HUB_URL="${HUB_URL:-http://127.0.0.1:8080}"
HTU="${HTU:-https://verifier.local/admission/check}"

ISSUER_A_CONTAINER="${ISSUER_A_CONTAINER:-issuer-hospitala}"

HOLDER_KEYS_DIR="${HOLDER_KEYS_DIR:-../vfp-governance/verifier/vault/holder_keys}"
GEN_MEMBER_KEYS="${GEN_MEMBER_KEYS:-../tools/gen_member_keys.py}"
MAKE_DPOP="${MAKE_DPOP:-../tools/make_dpop_jwt_eddsa.py}"

[[ -n "${ENVELOPE_ID}" ]] || {
  echo "Usage: $0 <active-envelope-id>" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing dependency: $1" >&2
    exit 1
  }
}

pass() {
  printf '\033[32m✓\033[0m %s\n' "$*"
}

fail() {
  printf '\033[31m✗\033[0m %s\n' "$*" >&2
  exit 1
}

section() {
  printf '\n============================================================\n'
  printf '%s\n' "$1"
  printf '============================================================\n'
}

for command in jq python3 curl docker; do
  need "${command}"
done

for container in fc-hub flower-server issuer-hospitala verifier-app; do
  docker ps --format '{{.Names}}' | grep -qx "${container}" \
    || fail "Container is not running: ${container}"
done

[[ -s "${HOLDER_KEYS_DIR}/Audrey.privhex" ]] \
  || fail "Missing Audrey holder key"

[[ -s "${GEN_MEMBER_KEYS}" ]] || fail "Missing ${GEN_MEMBER_KEYS}"
[[ -s "${MAKE_DPOP}" ]] || fail "Missing ${MAKE_DPOP}"

ARTIFACT_RUN_ID="$(
  docker exec flower-server \
    cat "/vault/${ENVELOPE_ID}/run.json" \
    | jq -er '.run_id'
)" || fail "Unable to resolve current model for envelope ${ENVELOPE_ID}"

docker exec flower-server \
  test -s "/vault/runs/${ARTIFACT_RUN_ID}/model.pt" \
  || fail "Missing current model artifact ${ARTIFACT_RUN_ID}"

holder_identity() {
  python3 "${GEN_MEMBER_KEYS}" \
    --derive \
    --private-key "${HOLDER_KEYS_DIR}/Audrey.privhex" \
    --format json
}

mint_ect() {
  docker exec -i "${ISSUER_A_CONTAINER}" \
    python3 - "Audrey" "${ENVELOPE_ID}" <<'PY'
import json
import sys
import requests

holder, envelope_id = sys.argv[1:]

response = requests.post(
    "http://127.0.0.1:8080/mint",
    json={
        "sub": holder,
        "envelope_id": envelope_id,
    },
    timeout=20,
)

try:
    body = response.json()
except Exception:
    body = response.text

print(json.dumps({"status": response.status_code, "body": body}))
PY
}

make_dpop() {
  local nonce="$1"
  local jti="$2"

  local identity holder_pub_b64
  identity="$(holder_identity)"
  holder_pub_b64="$(jq -er '.pub_b64' <<<"${identity}")"

  python3 "${MAKE_DPOP}" \
    "$(tr -d '\r\n' <"${HOLDER_KEYS_DIR}/Audrey.privhex")" \
    "${holder_pub_b64}" \
    "${nonce}" \
    "${jti}" \
    POST \
    "${HTU}" \
    "${ENVELOPE_ID}"
}

decode_dpop() {
  local token="$1"

  python3 - "${token}" <<'PY'
import base64
import json
import sys

parts = sys.argv[1].split(".")
if len(parts) != 3:
    raise SystemExit("not a compact JWS")

payload = parts[1]
payload += "=" * ((4 - len(payload) % 4) % 4)
print(json.dumps(
    json.loads(base64.urlsafe_b64decode(payload).decode("utf-8")),
    sort_keys=True,
))
PY
}

call_predict() {
  local ect="$1"
  local dpop="$2"
  local nonce="$3"
  local request="$4"

  curl -sS \
    -X POST "${HUB_URL}/predict" \
    -H 'Content-Type: application/json' \
    -H "Authorization: ECT ${ect}" \
    -H "DPoP: ${dpop}" \
    -H "X-DPoP-Nonce: ${nonce}" \
    --data "${request}"
}

section "1. Mint Audrey ECT"

MINT_A="$(mint_ect)"
[[ "$(jq -r '.status' <<<"${MINT_A}")" == "200" ]] \
  || fail "Audrey ECT mint failed: ${MINT_A}"

ECT_A="$(jq -r '.body.ect // .body.ect_jws // empty' <<<"${MINT_A}")"
[[ -n "${ECT_A}" ]] || fail "Audrey ECT is empty"

printf 'Envelope      : %s\n' "${ENVELOPE_ID}"
printf 'Current model : %s\n' "${ARTIFACT_RUN_ID}"
pass "Reusable Audrey ECT minted"

section "2. First presentation of proof A"

NONCE_A="nonce-Test4A-A-${RANDOM}-$(date +%s%N)"
JTI_A="jti-Test4A-A-${RANDOM}-$(date +%s%N)"
DPOP_A="$(make_dpop "${NONCE_A}" "${JTI_A}")"

REQUEST_A="$(
  jq -nc \
    --arg envelope_id "${ENVELOPE_ID}" \
    --arg run_id "${RUN_ID}" \
    --arg jti "${JTI_A}" \
    '{
      envelope_id: $envelope_id,
      run_id: $run_id,
      requested_tissues: ["lymphocytes"],
      jti: $jti,
      topk: 3
    }'
)"

echo "Proof A claims:"
decode_dpop "${DPOP_A}" | jq '{iat, jti, nonce, htm, htu, envelope_id}'

RESPONSE_1="$(call_predict "${ECT_A}" "${DPOP_A}" "${NONCE_A}" "${REQUEST_A}")"
echo "First response:"
jq '{admission, executed}' <<<"${RESPONSE_1}"

jq -e '
  .admission.allow == true
  and .executed == true
' <<<"${RESPONSE_1}" >/dev/null \
  || fail "First presentation of proof A was not ALLOW"

pass "First presentation of proof A is ALLOW"

section "3. Replay the exact same proof A"

RESPONSE_2="$(call_predict "${ECT_A}" "${DPOP_A}" "${NONCE_A}" "${REQUEST_A}")"
echo "Replay response:"
jq '{admission, executed}' <<<"${RESPONSE_2}"

jq -e '
  .admission.allow == false
  and .admission.reason == "dpop_replay"
  and .executed == false
' <<<"${RESPONSE_2}" >/dev/null \
  || fail "Exact replay was not denied with dpop_replay"

pass "Exact replay of proof A is DENY dpop_replay"

section "4. Same ECT with fresh proof B"

NONCE_B="nonce-Test4A-B-${RANDOM}-$(date +%s%N)"
JTI_B="jti-Test4A-B-${RANDOM}-$(date +%s%N)"
DPOP_B="$(make_dpop "${NONCE_B}" "${JTI_B}")"

REQUEST_B="$(
  jq -nc \
    --arg envelope_id "${ENVELOPE_ID}" \
    --arg run_id "${RUN_ID}" \
    --arg jti "${JTI_B}" \
    '{
      envelope_id: $envelope_id,
      run_id: $run_id,
      requested_tissues: ["lymphocytes"],
      jti: $jti,
      topk: 3
    }'
)"

echo "Proof B claims:"
decode_dpop "${DPOP_B}" | jq '{iat, jti, nonce, htm, htu, envelope_id}'

RESPONSE_3="$(call_predict "${ECT_A}" "${DPOP_B}" "${NONCE_B}" "${REQUEST_B}")"
echo "Fresh-proof response:"
jq '{admission, executed}' <<<"${RESPONSE_3}"

jq -e '
  .admission.allow == true
  and .executed == true
' <<<"${RESPONSE_3}" >/dev/null \
  || fail "Same ECT with fresh proof B was not ALLOW"

pass "Same ECT remains valid with fresh proof B"

section "5. Fix #4 replay invariant"

printf '%-20s %-8s %-20s %-9s\n' \
  "PRESENTATION" "ALLOW" "REASON" "EXECUTED"
printf '%s\n' \
  "--------------------------------------------------------------"

printf '%-20s %-8s %-20s %-9s\n' \
  "proof A first use" \
  "$(jq -r '.admission.allow' <<<"${RESPONSE_1}")" \
  "$(jq -r '.admission.reason // "-"' <<<"${RESPONSE_1}")" \
  "$(jq -r '.executed' <<<"${RESPONSE_1}")"

printf '%-20s %-8s %-20s %-9s\n' \
  "proof A replay" \
  "$(jq -r '.admission.allow' <<<"${RESPONSE_2}")" \
  "$(jq -r '.admission.reason // "-"' <<<"${RESPONSE_2}")" \
  "$(jq -r '.executed' <<<"${RESPONSE_2}")"

printf '%-20s %-8s %-20s %-9s\n' \
  "proof B fresh" \
  "$(jq -r '.admission.allow' <<<"${RESPONSE_3}")" \
  "$(jq -r '.admission.reason // "-"' <<<"${RESPONSE_3}")" \
  "$(jq -r '.executed' <<<"${RESPONSE_3}")"

echo
pass "Test4A passed: DPoP proofs are single-use while the ECT remains reusable"
