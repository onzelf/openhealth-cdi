#!/usr/bin/env bash
set -euo pipefail

# C2b — Hal -> Bob authority substitution
#
# Question:
#   Given that Hal knows the literal principal name "Bob", can Hal cause
#   Bob's authority to be minted or exercised without Bob's holder key?
#
# The test deliberately stops at proof of rejection.
#
# PASS:
#   1. Hal's key cannot mint a Bob ECT.
#   2. A valid Hal ECT + Hal DPoP cannot be presented as Bob.
#
# FAIL:
#   Hal obtains a Bob ECT or causes an operation to execute as Bob.
#
# Usage:
#   ./TestC2b_authority_substitution.sh <active-envelope-id>

ENVELOPE_ID="${1:-}"
[[ -n "${ENVELOPE_ID}" ]] || {
    echo "Usage: $0 <active-envelope-id>" >&2
    exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

HAL_CONTAINER="${HAL_CONTAINER:-hal}"
HUB_URL="${HUB_URL:-http://fc-hub:8080}"

ISSUER_IP="${ISSUER_IP:-127.0.0.1}"
ISSUER_PORT="${ISSUER_PORT:-9443}"

CA="${SRC_DIR}/vfp-governance/verifier/certs/ca.crt"
B_CRT="${SRC_DIR}/vfp-governance/verifier/certs/HospitalB-admin.crt"
B_KEY="${SRC_DIR}/vfp-governance/verifier/certs/HospitalB-admin.key"

MINT_PROOF_HTU="urn:openhealth:issuer:mint"
DPOP_HTU="https://verifier.local/admission/check"
RUN_ID="${RUN_ID:-local-pathmnist-ab-001}"
TISSUE="${TISSUE:-mucus}"

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

for cmd in docker jq curl python3; do
    command -v "${cmd}" >/dev/null 2>&1 ||
        fail "Missing command: ${cmd}"
done

for f in "${CA}" "${B_CRT}" "${B_KEY}"; do
    [[ -s "${f}" ]] || fail "Missing file: ${f}"
done

docker inspect "${HAL_CONTAINER}" >/dev/null 2>&1 ||
    fail "Hal container does not exist"


issuer_b_curl() {
    curl -sS \
        --resolve "issuer-hospitalb.local:${ISSUER_PORT}:${ISSUER_IP}" \
        --cacert "${CA}" \
        --cert "${B_CRT}" \
        --key "${B_KEY}" \
        "$@"
}


hal_sign_dpop() {
    local nonce="$1"
    local jti="$2"
    local htu="$3"

    docker exec -i \
        "${HAL_CONTAINER}" \
        python - \
        "${nonce}" \
        "${jti}" \
        "${htu}" \
        "${ENVELOPE_ID}" <<'PY'
import base64
import json
import sys
import time
from pathlib import Path
from cryptography.hazmat.primitives import serialization

nonce, jti, htu, envelope_id = sys.argv[1:5]

identity = Path("/var/lib/hal/identity")
key = serialization.load_pem_private_key(
    (identity / "holder.key").read_bytes(),
    password=None,
)
jwk = json.loads(
    (identity / "holder.jwk").read_text()
)

def b64(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()

def enc(obj):
    return b64(
        json.dumps(
            obj,
            sort_keys=True,
            separators=(",", ":"),
        ).encode()
    )

header = enc({
    "typ": "dpop+jwt",
    "alg": "EdDSA",
    "jwk": jwk,
})

payload = enc({
    "htu": htu,
    "htm": "POST",
    "iat": int(time.time()),
    "jti": jti,
    "nonce": nonce,
    "envelope_id": envelope_id,
})

signing_input = f"{header}.{payload}".encode()
signature = b64(key.sign(signing_input))

print(f"{header}.{payload}.{signature}")
PY
}


hal_http() {
    local method="$1"
    local path="$2"
    local body="${3:-}"
    local authorization="${4:-}"
    local dpop="${5:-}"
    local nonce="${6:-}"

    docker exec -i \
        -e HTTP_METHOD="${method}" \
        -e TARGET_URL="${HUB_URL}${path}" \
        -e REQUEST_BODY="${body}" \
        -e AUTHORIZATION="${authorization}" \
        -e DPOP="${dpop}" \
        -e DPOP_NONCE="${nonce}" \
        "${HAL_CONTAINER}" \
        python - <<'PY'
import json
import os
import urllib.error
import urllib.request

method = os.environ["HTTP_METHOD"]
url = os.environ["TARGET_URL"]
body = os.environ.get("REQUEST_BODY", "")

headers = {}
if body:
    headers["Content-Type"] = "application/json"

authorization = os.environ.get("AUTHORIZATION", "")
dpop = os.environ.get("DPOP", "")
nonce = os.environ.get("DPOP_NONCE", "")

if authorization:
    headers["Authorization"] = authorization
if dpop:
    headers["DPoP"] = dpop
if nonce:
    headers["X-DPoP-Nonce"] = nonce

request = urllib.request.Request(
    url,
    data=body.encode("utf-8") if body else None,
    headers=headers,
    method=method,
)

try:
    with urllib.request.urlopen(request, timeout=10) as response:
        status = response.status
        raw = response.read().decode("utf-8", errors="replace")
except urllib.error.HTTPError as exc:
    status = exc.code
    raw = exc.read().decode("utf-8", errors="replace")
except Exception as exc:
    print(json.dumps({
        "transport_error": str(exc),
    }))
    raise SystemExit(0)

try:
    parsed = json.loads(raw)
except Exception:
    parsed = raw

print(json.dumps({
    "status": status,
    "body": parsed,
}))
PY
}


section "1. Bob attack-target precondition"

MEMBERS="$(
    issuer_b_curl \
        "https://issuer-hospitalb.local:${ISSUER_PORT}/members"
)"

printf '%s' "${MEMBERS}" |
    jq -e '
        .members[]?
        | select(.sub == "Bob")
        | (.jkt | type == "string" and length > 0)
    ' >/dev/null ||
    fail "Precondition failed: Bob is not enrolled at Hospital B"

pass "Bob is an enrolled Hospital B holder"


section "2. Hal attempts to mint Bob's ECT"

MINT_NONCE="mint-$(python3 -c 'import secrets; print(secrets.token_urlsafe(12))')"
MINT_JTI="mint-$(python3 -c 'import secrets; print(secrets.token_urlsafe(12))')"

HAL_MINT_PROOF="$(
    hal_sign_dpop \
        "${MINT_NONCE}" \
        "${MINT_JTI}" \
        "${MINT_PROOF_HTU}"
)"

BOB_MINT_BODY="$(
    jq -nc \
        --arg e "${ENVELOPE_ID}" \
        --arg d "${HAL_MINT_PROOF}" \
        '{
            envelope_id:$e,
            holder_dpop:$d
        }'
)"

BOB_MINT_RESPONSE="$(
    hal_http \
        POST \
        "/administration/holders/Bob/mint-ect" \
        "${BOB_MINT_BODY}"
)"

if printf '%s' "${BOB_MINT_RESPONSE}" |
    jq -e '.transport_error' >/dev/null 2>&1
then
    printf '%s\n' "${BOB_MINT_RESPONSE}" | jq .
    fail "Transport failure is not evidence of authority separation"
fi

BOB_MINT_STATUS="$(
    printf '%s' "${BOB_MINT_RESPONSE}" |
        jq -r '.status'
)"

if [[ "${BOB_MINT_STATUS}" == "200" ]]; then
    printf '%s\n' "${BOB_MINT_RESPONSE}" | jq .
    fail "C2b: Hal obtained a credential while naming Bob"
fi

BOB_MINT_DETAIL="$(
    printf '%s' "${BOB_MINT_RESPONSE}" |
        jq -r '
            if (.body | type) == "object"
            then (.body.detail // "")
            else (.body // "")
            end
        '
)"

grep -q 'holder_mint_key_mismatch' <<<"${BOB_MINT_DETAIL}" || {
    printf '%s\n' "${BOB_MINT_RESPONSE}" | jq .
    fail "Unexpected Bob mint denial; expected holder_mint_key_mismatch"
}

pass "Hal's holder key cannot mint Bob's ECT"

# ---------------------------------------------------------------------
section "3. Obtain Hal's legitimate ECT"

HAL_MINT_NONCE="mint-$(python3 -c 'import secrets; print(secrets.token_urlsafe(12))')"
HAL_MINT_JTI="mint-$(python3 -c 'import secrets; print(secrets.token_urlsafe(12))')"

HAL_MINT_PROOF="$(
  hal_sign_dpop \
    "${HAL_MINT_NONCE}" \
    "${HAL_MINT_JTI}" \
    "${MINT_PROOF_HTU}"
)"

HAL_MINT_BODY="$(
  jq -nc \
    --arg e "${ENVELOPE_ID}" \
    --arg d "${HAL_MINT_PROOF}" \
    '{
      envelope_id: $e,
      holder_dpop: $d
    }'
)"

HAL_MINT_RESPONSE="$(
  hal_http \
    POST \
    "/administration/holders/Hal/mint-ect" \
    "${HAL_MINT_BODY}"
)"

HAL_ECT="$(
  printf '%s' "${HAL_MINT_RESPONSE}" |
    jq -r '
      if .status == 200
      then (.body.ect // "")
      else ""
      end
    '
)"

if [[ -z "${HAL_ECT}" ]]; then
  printf '%s\n' "${HAL_MINT_RESPONSE}" | jq .
  echo "! C2b HARNESS ERROR — unable to obtain Hal's legitimate ECT" >&2
  exit 70
fi

HAL_SUB="$(
  python3 - "${HAL_ECT}" <<'PY'
import base64
import json
import sys

token = sys.argv[1]
payload = token.split(".")[1]
payload += "=" * ((4 - len(payload) % 4) % 4)

claims = json.loads(base64.urlsafe_b64decode(payload))
print(claims.get("sub", ""))
PY
)"

if [[ "${HAL_SUB}" != "Hal" ]]; then
  echo "! C2b HARNESS ERROR — returned ECT is not bound to Hal" >&2
  exit 70
fi

pass "Hal possesses a valid Hal-bound ECT"

# -------------------------------------------------------------------
section "4. Hal presents its own authority while naming Bob"

NONCE="nonce-$(python3 -c 'import secrets; print(secrets.token_urlsafe(12))')"
JTI="jti-$(python3 -c 'import secrets; print(secrets.token_urlsafe(12))')"

HAL_DPOP="$(
    hal_sign_dpop \
        "${NONCE}" \
        "${JTI}" \
        "${DPOP_HTU}"
)"

INFERENCE_BODY="$(
    jq -nc \
        --arg e "${ENVELOPE_ID}" \
        --arg r "${RUN_ID}" \
        --arg j "${JTI}" \
        --arg t "${TISSUE}" \
        '{
            principal:"Bob",
            envelope_id:$e,
            run_id:$r,
            requested_tissue:$t,
            topk:3,
            jti:$j
        }'
)"

SUBSTITUTION_RESPONSE="$(
    hal_http \
        POST \
        "/user/inference" \
        "${INFERENCE_BODY}" \
        "ECT ${HAL_ECT}" \
        "${HAL_DPOP}" \
        "${NONCE}"
)"

if printf '%s' "${SUBSTITUTION_RESPONSE}" |
    jq -e '.transport_error' >/dev/null 2>&1
then
    printf '%s\n' "${SUBSTITUTION_RESPONSE}" | jq .
    fail "Transport failure is not evidence of authority separation"
fi

SUBSTITUTION_STATUS="$(
    printf '%s' "${SUBSTITUTION_RESPONSE}" |
        jq -r '.status'
)"

SUBSTITUTION_DETAIL="$(
    printf '%s' "${SUBSTITUTION_RESPONSE}" |
        jq -r '
            if (.body | type) == "object"
            then (.body.detail // "")
            else (.body // "")
            end
        '
)"

if [[ "${SUBSTITUTION_STATUS}" == "200" ]]; then
    printf '%s\n' "${SUBSTITUTION_RESPONSE}" | jq .
    fail "C2b: Hal successfully exercised an operation while naming Bob"
fi

[[ "${SUBSTITUTION_STATUS}" == "401" ]] || {
    printf '%s\n' "${SUBSTITUTION_RESPONSE}" | jq .
    fail "Unexpected authority-substitution result"
}

[[ "${SUBSTITUTION_DETAIL}" == "presented_ect_subject_mismatch" ]] || {
    printf '%s\n' "${SUBSTITUTION_RESPONSE}" | jq .
    fail "Expected presented_ect_subject_mismatch"
}

pass "Hal ECT + Hal DPoP cannot be presented as Bob"


section "5. C2b invariant"

printf '\n'
printf '%s\n' \
    'Knowing the literal principal "Bob" does not confer Bob authority.'
printf '%s\n' \
    'Bob authority requires Bob-bound holder proof.'
printf '\n'

pass "C2b GREEN — Hal cannot substitute itself for Bob"
