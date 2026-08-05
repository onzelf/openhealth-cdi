#!/usr/bin/env bash
set -euo pipefail

# Test4B — DPoP iat freshness
#
# Proves:
#   1. an old signed DPoP proof is denied with dpop_iat_stale;
#   2. a future-dated signed DPoP proof is denied with dpop_iat_future;
#   3. a current signed DPoP proof remains admissible.
#
# Usage:
#   ./Test4B_dpop_iat_freshness.sh <active-envelope-id>

ENVELOPE_ID="${1:-}"
RUN_ID="${RUN_ID:-local-pathmnist-ab-001}"

HUB_URL="${HUB_URL:-http://127.0.0.1:8080}"
HTU="${HTU:-https://verifier.local/admission/check}"

ISSUER_A_CONTAINER="${ISSUER_A_CONTAINER:-issuer-hospitala}"

HOLDER_KEYS_DIR="${HOLDER_KEYS_DIR:-../vfp-governance/verifier/vault/holder_keys}"
GEN_MEMBER_KEYS="${GEN_MEMBER_KEYS:-../tools/gen_member_keys.py}"

# Must be comfortably beyond the Gatekeeper defaults
# DPOP_MAX_AGE_SECONDS=60 and DPOP_CLOCK_SKEW_SECONDS=5.
STALE_OFFSET_SECONDS="${STALE_OFFSET_SECONDS:-120}"
FUTURE_OFFSET_SECONDS="${FUTURE_OFFSET_SECONDS:-120}"

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

make_dpop_at() {
  local nonce="$1"
  local jti="$2"
  local iat="$3"

  local identity holder_pub_b64 privhex
  identity="$(holder_identity)"
  holder_pub_b64="$(jq -er '.pub_b64' <<<"${identity}")"
  privhex="$(tr -d '\r\n' <"${HOLDER_KEYS_DIR}/Audrey.privhex")"

  python3 - \
    "${privhex}" \
    "${holder_pub_b64}" \
    "${nonce}" \
    "${jti}" \
    "${iat}" \
    "${HTU}" \
    "${ENVELOPE_ID}" <<'PY'
import base64
import json
import sys

from nacl import signing

priv_hex, pub_b64, nonce, jti, iat, htu, envelope_id = sys.argv[1:]

def b64u(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")

def b64u_json(obj) -> str:
    return b64u(
        json.dumps(
            obj,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
    )

header = {
    "typ": "dpop+jwt",
    "alg": "EdDSA",
    "jwk": {
        "kty": "OKP",
        "crv": "Ed25519",
        "x": pub_b64,
    },
}

payload = {
    "htu": htu,
    "htm": "POST",
    "iat": int(iat),
    "jti": jti,
    "nonce": nonce,
    "envelope_id": envelope_id,
}

h_b64 = b64u_json(header)
p_b64 = b64u_json(payload)
signing_input = f"{h_b64}.{p_b64}".encode("ascii")

sk = signing.SigningKey(bytes.fromhex(priv_hex))
sig = sk.sign(signing_input).signature

print(f"{h_b64}.{p_b64}.{b64u(sig)}")
PY
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

make_request() {
  local jti="$1"

  jq -nc \
    --arg envelope_id "${ENVELOPE_ID}" \
    --arg run_id "${RUN_ID}" \
    --arg jti "${jti}" \
    '{
      envelope_id: $envelope_id,
      run_id: $run_id,
      requested_tissues: ["lymphocytes"],
      jti: $jti,
      topk: 3
    }'
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
pass "Audrey ECT minted"

NOW="$(date +%s)"

section "2. Stale signed DPoP"

STALE_IAT="$((NOW - STALE_OFFSET_SECONDS))"
NONCE_STALE="nonce-Test4B-stale-${RANDOM}-$(date +%s%N)"
JTI_STALE="jti-Test4B-stale-${RANDOM}-$(date +%s%N)"
DPOP_STALE="$(make_dpop_at "${NONCE_STALE}" "${JTI_STALE}" "${STALE_IAT}")"
REQUEST_STALE="$(make_request "${JTI_STALE}")"

echo "Stale proof claims:"
decode_dpop "${DPOP_STALE}" | jq '{iat, jti, nonce, htm, htu, envelope_id}'

RESPONSE_STALE="$(
  call_predict \
    "${ECT_A}" \
    "${DPOP_STALE}" \
    "${NONCE_STALE}" \
    "${REQUEST_STALE}"
)"

echo "Stale response:"
jq '{admission, executed}' <<<"${RESPONSE_STALE}"

jq -e '
  .admission.allow == false
  and .admission.reason == "dpop_iat_stale"
  and .executed == false
' <<<"${RESPONSE_STALE}" >/dev/null \
  || fail "Stale DPoP was not denied with dpop_iat_stale"

pass "Stale DPoP is DENY dpop_iat_stale"

section "3. Future-dated signed DPoP"

FUTURE_IAT="$((NOW + FUTURE_OFFSET_SECONDS))"
NONCE_FUTURE="nonce-Test4B-future-${RANDOM}-$(date +%s%N)"
JTI_FUTURE="jti-Test4B-future-${RANDOM}-$(date +%s%N)"
DPOP_FUTURE="$(make_dpop_at "${NONCE_FUTURE}" "${JTI_FUTURE}" "${FUTURE_IAT}")"
REQUEST_FUTURE="$(make_request "${JTI_FUTURE}")"

echo "Future proof claims:"
decode_dpop "${DPOP_FUTURE}" | jq '{iat, jti, nonce, htm, htu, envelope_id}'

RESPONSE_FUTURE="$(
  call_predict \
    "${ECT_A}" \
    "${DPOP_FUTURE}" \
    "${NONCE_FUTURE}" \
    "${REQUEST_FUTURE}"
)"

echo "Future response:"
jq '{admission, executed}' <<<"${RESPONSE_FUTURE}"

jq -e '
  .admission.allow == false
  and .admission.reason == "dpop_iat_future"
  and .executed == false
' <<<"${RESPONSE_FUTURE}" >/dev/null \
  || fail "Future DPoP was not denied with dpop_iat_future"

pass "Future-dated DPoP is DENY dpop_iat_future"

section "4. Current signed DPoP"

FRESH_IAT="$(date +%s)"
NONCE_FRESH="nonce-Test4B-fresh-${RANDOM}-$(date +%s%N)"
JTI_FRESH="jti-Test4B-fresh-${RANDOM}-$(date +%s%N)"
DPOP_FRESH="$(make_dpop_at "${NONCE_FRESH}" "${JTI_FRESH}" "${FRESH_IAT}")"
REQUEST_FRESH="$(make_request "${JTI_FRESH}")"

echo "Fresh proof claims:"
decode_dpop "${DPOP_FRESH}" | jq '{iat, jti, nonce, htm, htu, envelope_id}'

RESPONSE_FRESH="$(
  call_predict \
    "${ECT_A}" \
    "${DPOP_FRESH}" \
    "${NONCE_FRESH}" \
    "${REQUEST_FRESH}"
)"

echo "Fresh response:"
jq '{admission, executed}' <<<"${RESPONSE_FRESH}"

jq -e '
  .admission.allow == true
  and .executed == true
' <<<"${RESPONSE_FRESH}" >/dev/null \
  || fail "Current DPoP was not admitted"

pass "Current DPoP remains ALLOW"

section "5. Fix #4 freshness invariant"

printf '%-16s %-12s %-8s %-20s %-9s\n' \
  "PROOF" "IAT" "ALLOW" "REASON" "EXECUTED"
printf '%s\n' \
  "--------------------------------------------------------------------------"

printf '%-16s %-12s %-8s %-20s %-9s\n' \
  "stale" \
  "${STALE_IAT}" \
  "$(jq -r '.admission.allow' <<<"${RESPONSE_STALE}")" \
  "$(jq -r '.admission.reason // "-"' <<<"${RESPONSE_STALE}")" \
  "$(jq -r '.executed' <<<"${RESPONSE_STALE}")"

printf '%-16s %-12s %-8s %-20s %-9s\n' \
  "future" \
  "${FUTURE_IAT}" \
  "$(jq -r '.admission.allow' <<<"${RESPONSE_FUTURE}")" \
  "$(jq -r '.admission.reason // "-"' <<<"${RESPONSE_FUTURE}")" \
  "$(jq -r '.executed' <<<"${RESPONSE_FUTURE}")"

printf '%-16s %-12s %-8s %-20s %-9s\n' \
  "fresh" \
  "${FRESH_IAT}" \
  "$(jq -r '.admission.allow' <<<"${RESPONSE_FRESH}")" \
  "$(jq -r '.admission.reason // "-"' <<<"${RESPONSE_FRESH}")" \
  "$(jq -r '.executed' <<<"${RESPONSE_FRESH}")"

echo
pass "Test4B passed: DPoP iat freshness is enforced"
