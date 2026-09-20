#!/usr/bin/env bash
set -euo pipefail

# Test2G — holder-authenticated issuer minting.
#
# Falsification target:
#   possession of an enrolled holder key is necessary for /mint.
#   A caller that can choose only {sub, envelope_id} must not be able to mint.
#
# Usage:
#   ISSUER_IP=127.0.0.1 ./Test2G_holder_mint_proof.sh <active-envelope-id>

ENVELOPE_ID="${1:-}"
[[ -n "${ENVELOPE_ID}" ]] || {
  echo "Usage: $0 <active-envelope-id>" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ISSUER_IP="${ISSUER_IP:-127.0.0.1}"
ISSUER_PORT="${ISSUER_PORT:-9443}"
ISSUER_HOST="${ISSUER_HOST:-issuer-hospitala.local}"
ISSUER_URL="https://${ISSUER_HOST}:${ISSUER_PORT}"
HAL_CONTAINER="${HAL_CONTAINER:-hal}"

MINT_PROOF_HTU="urn:openhealth:issuer:mint"
ADMISSION_HTU="https://verifier.local/admission/check"

CA="${SRC_DIR}/vfp-governance/verifier/certs/ca.crt"
A_CRT="${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.crt"
A_KEY="${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.key"
AUDREY_PRIVATE="${SRC_DIR}/../secrets/holder_keys/Audrey.privhex"
GEN_MEMBER_KEYS="${SRC_DIR}/tools/gen_member_keys.py"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

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

for cmd in curl jq python3 docker; do
  command -v "${cmd}" >/dev/null 2>&1 \
    || fail "Missing command: ${cmd}"
done

for file in \
  "${CA}" \
  "${A_CRT}" \
  "${A_KEY}" \
  "${AUDREY_PRIVATE}" \
  "${GEN_MEMBER_KEYS}"; do
  [[ -s "${file}" ]] || fail "Missing or empty file: ${file}"
done

CURL_ISSUER=(
  -sS
  --resolve "${ISSUER_HOST}:${ISSUER_PORT}:${ISSUER_IP}"
  --cacert "${CA}"
  --cert "${A_CRT}"
  --key "${A_KEY}"
)

issuer_request() {
  local method="$1"
  local path="$2"
  local data="$3"
  local output="$4"

  curl "${CURL_ISSUER[@]}" \
    -o "${output}" \
    -w '%{http_code}' \
    -X "${method}" \
    "${ISSUER_URL}${path}" \
    -H 'content-type: application/json' \
    -d "${data}"
}

holder_identity() {
  local private_key="$1"

  python3 "${GEN_MEMBER_KEYS}" \
    --derive \
    --private-key "${private_key}" \
    --format json
}

random_private_hex() {
  python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
}

make_proof() {
  local private_hex="$1"
  local proof_envelope="$2"
  local htu="$3"
  local iat="$4"
  local jti="$5"
  local nonce="$6"
  local tamper="${7:-0}"

  python3 - \
    "${private_hex}" \
    "${proof_envelope}" \
    "${htu}" \
    "${iat}" \
    "${jti}" \
    "${nonce}" \
    "${tamper}" <<'PY'
import base64
import json
import sys

from nacl import signing

private_hex, envelope_id, htu, iat, jti, nonce, tamper = sys.argv[1:]

def b64u(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")

def enc(obj) -> str:
    return b64u(
        json.dumps(
            obj,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    )

key = signing.SigningKey(bytes.fromhex(private_hex))
pub = b64u(key.verify_key.encode())

header = enc({
    "typ": "dpop+jwt",
    "alg": "EdDSA",
    "jwk": {
        "kty": "OKP",
        "crv": "Ed25519",
        "x": pub,
    },
})
claims = enc({
    "htu": htu,
    "htm": "POST",
    "iat": int(iat),
    "jti": jti,
    "nonce": nonce,
    "envelope_id": envelope_id,
})
signing_input = f"{header}.{claims}".encode("ascii")
signature = bytearray(key.sign(signing_input).signature)

if tamper == "1":
    signature[0] ^= 0x01

print(f"{header}.{claims}.{b64u(bytes(signature))}")
PY
}

hal_make_mint_proof() {
  local jti="$1"
  local nonce="$2"

  docker exec -i "${HAL_CONTAINER}" \
    python - \
      "${ENVELOPE_ID}" \
      "${MINT_PROOF_HTU}" \
      "${jti}" \
      "${nonce}" <<'PY'
import base64
import json
import sys
import time
from pathlib import Path

from cryptography.hazmat.primitives import serialization

envelope_id, htu, jti, nonce = sys.argv[1:]

identity = Path("/var/lib/hal/identity")
key = serialization.load_pem_private_key(
    (identity / "holder.key").read_bytes(),
    password=None,
)
jwk = json.loads((identity / "holder.jwk").read_text())

def b64u(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")

def enc(obj) -> str:
    return b64u(
        json.dumps(
            obj,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    )

header = enc({
    "typ": "dpop+jwt",
    "alg": "EdDSA",
    "jwk": jwk,
})
claims = enc({
    "htu": htu,
    "htm": "POST",
    "iat": int(time.time()),
    "jti": jti,
    "nonce": nonce,
    "envelope_id": envelope_id,
})
signing_input = f"{header}.{claims}".encode("ascii")
signature = key.sign(signing_input)

print(f"{header}.{claims}.{b64u(signature)}")
PY
}

mint_payload() {
  local subject="$1"
  local envelope="$2"
  local proof="$3"

  jq -nc \
    --arg sub "${subject}" \
    --arg envelope "${envelope}" \
    --arg proof "${proof}" \
    '{
      sub: $sub,
      envelope_id: $envelope,
      holder_dpop: $proof
    }'
}

expect_detail() {
  local label="$1"
  local expected_status="$2"
  local expected_detail="$3"
  local subject="$4"
  local proof="$5"

  local output="${TMP}/${label}.json"
  local status
  status="$(
    issuer_request \
      POST \
      /mint \
      "$(mint_payload "${subject}" "${ENVELOPE_ID}" "${proof}")" \
      "${output}"
  )"

  [[ "${status}" == "${expected_status}" ]] || {
    cat "${output}" >&2 || true
    fail "${label}: expected HTTP ${expected_status}, got ${status}"
  }

  jq -e \
    --arg expected "${expected_detail}" \
    '.detail == $expected' \
    "${output}" >/dev/null || {
      cat "${output}" >&2 || true
      fail "${label}: expected detail '${expected_detail}'"
    }

  pass "${label}: HTTP ${expected_status} ${expected_detail}"
}

expect_allow() {
  local label="$1"
  local subject="$2"
  local proof="$3"

  local output="${TMP}/${label}.json"
  local status
  status="$(
    issuer_request \
      POST \
      /mint \
      "$(mint_payload "${subject}" "${ENVELOPE_ID}" "${proof}")" \
      "${output}"
  )"

  [[ "${status}" == "200" ]] || {
    cat "${output}" >&2 || true
    fail "${label}: expected HTTP 200, got ${status}"
  }

  jq -e '.ect | type == "string" and length > 0' \
    "${output}" >/dev/null \
    || fail "${label}: issuer returned no ECT"

  pass "${label}: holder-authenticated mint ALLOW"
}

unique_token() {
  local prefix="$1"
  printf '%s-%s-%s-%s' \
    "${prefix}" \
    "$$" \
    "${RANDOM}" \
    "$(date +%s%N)"
}

section "0. Verify enrolled human identities"

AUDREY_IDENTITY="$(holder_identity "${AUDREY_PRIVATE}")"
AUDREY_PUB="$(jq -er '.pub_b64' <<<"${AUDREY_IDENTITY}")"
AUDREY_JKT="$(jq -er '.jkt' <<<"${AUDREY_IDENTITY}")"
AUDREY_PRIV_HEX="$(tr -d '\r\n' <"${AUDREY_PRIVATE}")"

MEMBERS_FILE="${TMP}/members.json"
MEMBERS_STATUS="$(
  curl "${CURL_ISSUER[@]}" \
    -o "${MEMBERS_FILE}" \
    -w '%{http_code}' \
    "${ISSUER_URL}/members"
)"

[[ "${MEMBERS_STATUS}" == "200" ]] || {
  cat "${MEMBERS_FILE}" >&2 || true
  fail "Issuer /members returned HTTP ${MEMBERS_STATUS}"
}

jq -e \
  --arg pub "${AUDREY_PUB}" \
  --arg jkt "${AUDREY_JKT}" \
  '
    .members[]
    | select(
        .sub == "Audrey"
        and .pub_b64 == $pub
        and .jkt == $jkt
      )
  ' "${MEMBERS_FILE}" >/dev/null \
  || fail "Audrey private key does not match issuer enrollment"

jq -e \
  '.members[] | select(.sub == "Charlie")' \
  "${MEMBERS_FILE}" >/dev/null \
  || fail "Charlie is not enrolled with Hospital A"

pass "Audrey and Charlie enrollment prerequisites are valid"

section "1. Valid enrolled holder proof"

PROOF_VALID="$(
  make_proof \
    "${AUDREY_PRIV_HEX}" \
    "${ENVELOPE_ID}" \
    "${MINT_PROOF_HTU}" \
    "$(date +%s)" \
    "$(unique_token jti-valid)" \
    "$(unique_token nonce-valid)"
)"
expect_allow "valid-holder-proof" "Audrey" "${PROOF_VALID}"

VALID_ECT="$(jq -r '.ect' "${TMP}/valid-holder-proof.json")"
python3 - "${VALID_ECT}" >"${TMP}/valid-claims.json" <<'PY'
import base64
import json
import sys

parts = sys.argv[1].split(".")
if len(parts) != 3:
    raise SystemExit("not_compact_jws")

payload = parts[1] + "=" * ((4 - len(parts[1]) % 4) % 4)
print(json.dumps(
    json.loads(base64.urlsafe_b64decode(payload)),
    indent=2,
    sort_keys=True,
))
PY

jq -e \
  --arg envelope "${ENVELOPE_ID}" \
  --arg jkt "${AUDREY_JKT}" \
  '
    .sub == "Audrey"
    and .envelope_id == $envelope
    and .cnf.jkt == $jkt
  ' "${TMP}/valid-claims.json" >/dev/null \
  || fail "Minted ECT is not bound to Audrey, the envelope and Audrey JKT"

pass "Minted ECT preserves holder and envelope binding"

section "2. Missing proof"

MISSING_FILE="${TMP}/missing-proof.json"
MISSING_STATUS="$(
  issuer_request \
    POST \
    /mint \
    "$(jq -nc \
      --arg sub "Audrey" \
      --arg envelope "${ENVELOPE_ID}" \
      '{sub:$sub,envelope_id:$envelope}')" \
    "${MISSING_FILE}"
)"

[[ "${MISSING_STATUS}" == "422" ]] || {
  cat "${MISSING_FILE}" >&2 || true
  fail "missing-proof: expected HTTP 422, got ${MISSING_STATUS}"
}

jq -e '
  .detail[]
  | select((.loc[-1] // "") == "holder_dpop")
' "${MISSING_FILE}" >/dev/null \
  || fail "missing-proof: holder_dpop was not identified as required"

pass "missing-proof: DENY before mint"

section "3. Wrong holder key"

WRONG_PRIVATE_HEX="$(random_private_hex)"
PROOF_WRONG_KEY="$(
  make_proof \
    "${WRONG_PRIVATE_HEX}" \
    "${ENVELOPE_ID}" \
    "${MINT_PROOF_HTU}" \
    "$(date +%s)" \
    "$(unique_token jti-wrong-key)" \
    "$(unique_token nonce-wrong-key)"
)"
expect_detail \
  "wrong-holder-key" \
  "401" \
  "holder_mint_key_mismatch" \
  "Audrey" \
  "${PROOF_WRONG_KEY}"

section "4. Wrong envelope binding"

PROOF_WRONG_ENVELOPE="$(
  make_proof \
    "${AUDREY_PRIV_HEX}" \
    "${ENVELOPE_ID}-other" \
    "${MINT_PROOF_HTU}" \
    "$(date +%s)" \
    "$(unique_token jti-wrong-envelope)" \
    "$(unique_token nonce-wrong-envelope)"
)"
expect_detail \
  "wrong-envelope" \
  "401" \
  "holder_mint_envelope_mismatch" \
  "Audrey" \
  "${PROOF_WRONG_ENVELOPE}"

section "5. Stale proof"

PROOF_STALE="$(
  make_proof \
    "${AUDREY_PRIV_HEX}" \
    "${ENVELOPE_ID}" \
    "${MINT_PROOF_HTU}" \
    "$(( $(date +%s) - 300 ))" \
    "$(unique_token jti-stale)" \
    "$(unique_token nonce-stale)"
)"
expect_detail \
  "stale-proof" \
  "401" \
  "holder_mint_proof_expired" \
  "Audrey" \
  "${PROOF_STALE}"

section "6. Future-dated proof"

PROOF_FUTURE="$(
  make_proof \
    "${AUDREY_PRIV_HEX}" \
    "${ENVELOPE_ID}" \
    "${MINT_PROOF_HTU}" \
    "$(( $(date +%s) + 300 ))" \
    "$(unique_token jti-future)" \
    "$(unique_token nonce-future)"
)"
expect_detail \
  "future-proof" \
  "401" \
  "holder_mint_proof_from_future" \
  "Audrey" \
  "${PROOF_FUTURE}"

section "7. Wrong proof target"

PROOF_WRONG_HTU="$(
  make_proof \
    "${AUDREY_PRIV_HEX}" \
    "${ENVELOPE_ID}" \
    "${ADMISSION_HTU}" \
    "$(date +%s)" \
    "$(unique_token jti-wrong-htu)" \
    "$(unique_token nonce-wrong-htu)"
)"
expect_detail \
  "wrong-htu" \
  "401" \
  "holder_mint_htu_mismatch" \
  "Audrey" \
  "${PROOF_WRONG_HTU}"

section "8. Tampered signature"

PROOF_TAMPERED="$(
  make_proof \
    "${AUDREY_PRIV_HEX}" \
    "${ENVELOPE_ID}" \
    "${MINT_PROOF_HTU}" \
    "$(date +%s)" \
    "$(unique_token jti-tampered)" \
    "$(unique_token nonce-tampered)" \
    "1"
)"
expect_detail \
  "tampered-signature" \
  "401" \
  "invalid_holder_mint_signature" \
  "Audrey" \
  "${PROOF_TAMPERED}"

section "9. Caller-selected subject substitution"

PROOF_AUDREY_FOR_CHARLIE="$(
  make_proof \
    "${AUDREY_PRIV_HEX}" \
    "${ENVELOPE_ID}" \
    "${MINT_PROOF_HTU}" \
    "$(date +%s)" \
    "$(unique_token jti-substitution)" \
    "$(unique_token nonce-substitution)"
)"
expect_detail \
  "audrey-proof-for-charlie" \
  "401" \
  "holder_mint_key_mismatch" \
  "Charlie" \
  "${PROOF_AUDREY_FOR_CHARLIE}"

section "10. Replay protection"

REPLAY_JTI="$(unique_token jti-replay)"
REPLAY_NONCE="$(unique_token nonce-replay)"
PROOF_REPLAY="$(
  make_proof \
    "${AUDREY_PRIV_HEX}" \
    "${ENVELOPE_ID}" \
    "${MINT_PROOF_HTU}" \
    "$(date +%s)" \
    "${REPLAY_JTI}" \
    "${REPLAY_NONCE}"
)"

expect_allow "replay-first-use" "Audrey" "${PROOF_REPLAY}"
expect_detail \
  "replay-second-use" \
  "409" \
  "mint_proof_replayed" \
  "Audrey" \
  "${PROOF_REPLAY}"

section "11. Hal local holder key"

docker inspect "${HAL_CONTAINER}" >/dev/null 2>&1 \
  || fail "Hal container is unavailable"

HAL_JWK="$(
  docker exec "${HAL_CONTAINER}" \
    cat /var/lib/hal/identity/holder.jwk
)"
HAL_JKT="$(
  docker exec "${HAL_CONTAINER}" \
    cat /var/lib/hal/identity/holder.jkt \
    | tr -d '\r\n'
)"
HAL_PUB="$(jq -er '.x' <<<"${HAL_JWK}")"

[[ -n "${HAL_PUB}" && -n "${HAL_JKT}" ]] \
  || fail "Hal public identity is incomplete"

MEMBERS="$(
  curl "${CURL_ISSUER[@]}" \
    "${ISSUER_URL}/members"
)"
HAL_EXISTING_JKT="$(
  jq -r \
    '.members[]? | select(.sub == "Hal") | .jkt' \
    <<<"${MEMBERS}" \
    | head -n1
)"

if [[ -z "${HAL_EXISTING_JKT}" ]]; then
  HAL_REGISTER_FILE="${TMP}/hal-register.json"
  HAL_REGISTER_STATUS="$(
    issuer_request \
      POST \
      /members/register \
      "$(jq -nc \
        --arg pub "${HAL_PUB}" \
        --arg jkt "${HAL_JKT}" \
        '{
          org_id:"org://HospitalA",
          member_id:"hal-mode1b",
          sub:"Hal",
          pub_b64:$pub,
          jkt:$jkt
        }')" \
      "${HAL_REGISTER_FILE}"
  )"

  [[ "${HAL_REGISTER_STATUS}" == "200" ]] || {
    cat "${HAL_REGISTER_FILE}" >&2 || true
    fail "Hal registration returned HTTP ${HAL_REGISTER_STATUS}"
  }
else
  [[ "${HAL_EXISTING_JKT}" == "${HAL_JKT}" ]] \
    || fail "Hal issuer JKT does not match Hal local holder key"
fi

HAL_PROOF="$(
  hal_make_mint_proof \
    "$(unique_token jti-hal)" \
    "$(unique_token nonce-hal)"
)"
expect_allow "hal-local-holder-proof" "Hal" "${HAL_PROOF}"

section "12. Holder-mint invariant"

printf '%-42s %s\n' "CASE" "RESULT"
printf '%s\n' "---------------------------------------------------------------"
printf '%-42s %s\n' "valid enrolled Audrey proof" "ALLOW"
printf '%-42s %s\n' "missing proof" "DENY"
printf '%-42s %s\n' "wrong key" "DENY"
printf '%-42s %s\n' "wrong envelope" "DENY"
printf '%-42s %s\n' "stale proof" "DENY"
printf '%-42s %s\n' "future proof" "DENY"
printf '%-42s %s\n' "admission HTU used for mint" "DENY"
printf '%-42s %s\n' "tampered signature" "DENY"
printf '%-42s %s\n' "Audrey proof used for Charlie" "DENY"
printf '%-42s %s\n' "replayed mint proof" "DENY"
printf '%-42s %s\n' "Hal local holder proof" "ALLOW"

echo
pass "Test2G passed: issuer mint authority requires the enrolled holder relation"
