#!/usr/bin/env bash
# TestA8_cross_envelope_authority.sh
#
# Attack:
#   Test whether an ECT constituted under envelope E1 can be reused to
#   authorize an operation whose governance context is a distinct envelope E2.
#
# Method:
#   1. Verify E1 is a legitimate active envelope and is the current control
#      context used to establish the positive control.
#   2. Mint a real Audrey ECT under E1.
#   3. Generate fresh DPoP(E1) and prove ECT(E1) authorizes the exact E1
#      request. This establishes that the credential is live and usable.
#   4. Create (or reuse) a distinct legitimate ACTIVE envelope E2 through the
#      normal KYO/verifier path.
#   5. Keep the E1 ECT unchanged, generate fresh DPoP(E2), and submit the same
#      semantic operation with envelope_id=E2.
#
# Security invariant:
#   Authority is envelope-local. Evidence constituted under E1 must not
#   authorize an operation governed by E2.
#
# A8 is CONFIRMED if Gatekeeper returns ALLOW for the E2 request while the
# presented ECT was minted under E1.
#
# A8 is NOT CONFIRMED only when the cross-envelope request is explicitly
# rejected for envelope_mismatch. Other rejection reasons are treated as a
# harness/precondition failure because they do not establish this invariant.
#
# Usage:
#   ./TestA8_cross_envelope_authority.sh <E1>
#
# Security verdict:
#   rc=0  A8 NOT CONFIRMED / ECT(E1) cannot authorize E2
#   rc=1  A8 CONFIRMED / ECT(E1) crossed the envelope boundary into E2
#
# Harness/precondition failure:
#   rc=70

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

E1="${1:-}"
[[ -n "${E1}" ]] || {
    printf 'Usage: %s <currently-selected-E1>\n' "$0" >&2
    exit 70
}

HUB_URL="${HUB_URL:-http://127.0.0.1:8080}"
VERIFIER_HOST="${VERIFIER_HOST:-verifier.local}"
VERIFIER_PORT="${VERIFIER_PORT:-8443}"
VERIFIER_IP="${VERIFIER_IP:-127.0.0.1}"

ISSUER_HOST="${ISSUER_HOST:-issuer-hospitala.local}"
ISSUER_PORT="${ISSUER_PORT:-9443}"
ISSUER_IP="${ISSUER_IP:-127.0.0.1}"

RUN_ID="${RUN_ID:-local-pathmnist-ab-001}"
SUBJECT="${SUBJECT:-Audrey}"
TISSUE="${TISSUE:-mucus}"

CA="${SRC_DIR}/vfp-governance/verifier/certs/ca.crt"
HUB_CRT="${SRC_DIR}/vfp-governance/verifier/certs/hub.crt"
HUB_KEY="${SRC_DIR}/vfp-governance/verifier/certs/hub.key"
A_CRT="${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.crt"
A_KEY="${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.key"
B_CRT="${SRC_DIR}/vfp-governance/verifier/certs/HospitalB-admin.crt"
B_KEY="${SRC_DIR}/vfp-governance/verifier/certs/HospitalB-admin.key"

HOLDER_PRIVATE="${HOLDER_PRIVATE:-${SRC_DIR}/../secrets/holder_keys/${SUBJECT}.privhex}"
GEN_MEMBER_KEYS="${SRC_DIR}/tools/gen_member_keys.py"
MAKE_DPOP="${SRC_DIR}/tools/make_dpop_jwt_eddsa.py"

DPOP_HTU="https://${VERIFIER_HOST}/admission/check"
MINT_PROOF_HTU="${MINT_PROOF_HTU:-urn:openhealth:issuer:mint}"
E2_CACHE="${SCRIPT_DIR}/.a8_cross_envelope_id"

TMP="$(mktemp -d)"
E2=""

pass() {
    printf '\033[32m✓\033[0m %s\n' "$*"
}

note() {
    printf '\033[36m·\033[0m %s\n' "$*"
}

section() {
    printf '\n============================================================\n'
    printf '%s\n' "$1"
    printf '============================================================\n'
}

harness_fail() {
    printf '\n\033[31mHARNESS ERROR\033[0m\n' >&2
    printf '%s\n' "$*" >&2
    exit 70
}

protected() {
    printf '\n\033[32mA8 NOT CONFIRMED\033[0m\n'
    printf '%s\n' "$*"
    exit 0
}

confirmed() {
    printf '\n\033[31mA8 CONFIRMED\033[0m\n'
    printf '%s\n' "$*"
    exit 1
}

cleanup() {
    local rc=$?
    local current=""

    set +e

    current="$(
        curl -fsS "${HUB_URL}/administration/boundary" 2>/dev/null |
        jq -r '.selected_envelope_id // empty' 2>/dev/null
    )"

    if [[ -n "${E1}" && "${current}" != "${E1}" ]]; then
        curl -fsS -X POST \
            -H 'content-type: application/json' \
            -d '{}' \
            "${HUB_URL}/administration/envelopes/${E1}/select" \
            >/dev/null 2>&1 || \
            printf '%s\n' \
                "! A8 CLEANUP WARNING Could not restore E1 ${E1}" >&2
    fi

    rm -rf "${TMP}"
    exit "${rc}"
}
trap cleanup EXIT

for cmd in curl jq grep sed docker python3; do
    command -v "${cmd}" >/dev/null 2>&1 ||
        harness_fail "Missing command: ${cmd}"
done

for file in \
    "${CA}" \
    "${HUB_CRT}" "${HUB_KEY}" \
    "${A_CRT}" "${A_KEY}" \
    "${B_CRT}" "${B_KEY}" \
    "${HOLDER_PRIVATE}" "${GEN_MEMBER_KEYS}" "${MAKE_DPOP}"; do
    [[ -s "${file}" ]] || harness_fail "Missing file: ${file}"
done

for container in fc-hub flower-server; do
    docker inspect "${container}" >/dev/null 2>&1 ||
        harness_fail "Missing container: ${container}"
done

HOLDER_IDENTITY="$(
    python3 "${GEN_MEMBER_KEYS}" \
        --derive \
        --private-key "${HOLDER_PRIVATE}" \
        --format json
)" || harness_fail "Cannot derive ${SUBJECT} holder identity"

HOLDER_PUB_B64="$(jq -er '.pub_b64' <<<"${HOLDER_IDENTITY}")" ||
    harness_fail "Cannot derive ${SUBJECT} public key"

HOLDER_PRIV_HEX="$(tr -d '\r\n' <"${HOLDER_PRIVATE}")"
[[ -n "${HOLDER_PRIV_HEX}" ]] ||
    harness_fail "Cannot read ${SUBJECT} private holder key"

verifier_curl() {
    local crt="$1"
    local key="$2"
    shift 2

    curl -sS \
        --resolve "${VERIFIER_HOST}:${VERIFIER_PORT}:${VERIFIER_IP}" \
        --cacert "${CA}" \
        --cert "${crt}" \
        --key "${key}" \
        "$@"
}

issuer_curl() {
    curl -sS \
        --resolve "${ISSUER_HOST}:${ISSUER_PORT}:${ISSUER_IP}" \
        --cacert "${CA}" \
        --cert "${A_CRT}" \
        --key "${A_KEY}" \
        "$@"
}

hub_get() {
    curl -fsS "${HUB_URL}$1"
}

hub_post() {
    local path="$1"
    local data="${2:-}"
    if [[ -n "${data}" ]]; then
        curl -fsS \
            -X POST \
            -H 'content-type: application/json' \
            -d "${data}" \
            "${HUB_URL}${path}"
    else
        curl -fsS -X POST "${HUB_URL}${path}"
    fi
}

sign_dpop() {
    local envelope="$1"
    local jti="$2"
    local nonce="${jti}-nonce"

    python3 - \
        "${HOLDER_PRIV_HEX}" \
        "${HOLDER_PUB_B64}" \
        "${nonce}" \
        "${jti}" \
        "${DPOP_HTU}" \
        "${envelope}" \
        "${RUN_ID}" \
        "${TISSUE}" <<'PY'
import base64
import hashlib
import json
import sys
import time
from nacl import signing

(
    priv_hex,
    pub_b64,
    nonce,
    jti,
    htu,
    envelope_id,
    run_id,
    tissue,
) = sys.argv[1:]

def b64u(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")

def enc(value) -> str:
    return b64u(
        json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
        ).encode("utf-8")
    )

governed_request = {
    "envelope_id": envelope_id,
    "run_id": run_id,
    "resource": "pathmnist-colon-pathology",
    "action": "query_model",
    "purpose": "approved_model_query",
    "requested_tissues": [tissue],
}

canonical = json.dumps(
    governed_request,
    sort_keys=True,
    separators=(",", ":"),
    ensure_ascii=False,
).encode("utf-8")

request_hash = "sha256:" + hashlib.sha256(canonical).hexdigest()

header = {
    "typ": "dpop+jwt",
    "alg": "EdDSA",
    "jwk": {
        "kty": "OKP",
        "crv": "Ed25519",
        "x": pub_b64,
    },
}

claims = {
    "htu": htu,
    "htm": "POST",
    "iat": int(time.time()),
    "jti": jti,
    "nonce": nonce,
    "envelope_id": envelope_id,
    "request_hash": request_hash,
}

h = enc(header)
p = enc(claims)
signing_input = f"{h}.{p}".encode("ascii")
sig = signing.SigningKey(bytes.fromhex(priv_hex)).sign(signing_input).signature
dpop = f"{h}.{p}.{b64u(sig)}"

print(json.dumps({
    "http_status": 200,
    "body": {
        "dpop": dpop,
        "request_hash": request_hash,
        "nonce": nonce,
    },
}))
PY
}

admit_request() {
    local ect="$1"
    local dpop="$2"
    local nonce="$3"
    local jti="$4"
    local envelope="$5"
    local outfile="$6"

    local body status

    body="$(
        jq -nc \
            --arg e "${envelope}" \
            --arg r "${RUN_ID}" \
            --arg t "${TISSUE}" \
            --arg j "${jti}" '
            {
              envelope_id:$e,
              run_id:$r,
              resource:"pathmnist-colon-pathology",
              action:"query_model",
              purpose:"approved_model_query",
              requested_tissues:[$t],
              jti:$j
            }'
    )"

    status="$(
        curl -sS \
            --resolve "${VERIFIER_HOST}:${VERIFIER_PORT}:${VERIFIER_IP}" \
            --cacert "${CA}" \
            --cert "${HUB_CRT}" \
            --key "${HUB_KEY}" \
            -o "${outfile}" \
            -w '%{http_code}' \
            -X POST \
            -H 'content-type: application/json' \
            -H "Authorization: ECT ${ect}" \
            -H "DPoP: ${dpop}" \
            -H "X-DPoP-Nonce: ${nonce}" \
            -d "${body}" \
            "https://${VERIFIER_HOST}:${VERIFIER_PORT}/admission/check"
    )"

    [[ "${status}" == "200" ]] || {
        cat "${outfile}" >&2 || true
        harness_fail "Gatekeeper admission returned HTTP ${status}"
    }
}

extract_kyo_code() {
    local crt="$1"
    local key="$2"
    local html code

    html="$(
        verifier_curl \
            "${crt}" "${key}" \
            "https://${VERIFIER_HOST}:${VERIFIER_PORT}/verify-start"
    )" || return 1

    code="$(
        printf '%s' "${html}" |
            grep -oE '[0-9]{6}' |
            head -n1
    )"

    [[ "${code}" =~ ^[0-9]{6}$ ]] || return 1
    printf '%s' "${code}"
}

create_e2() {
    local begin bind_id code_a code_b approve_a approve_b candidate

    begin="$(hub_post /administration/kyo/binds '{}')" ||
        harness_fail "Cannot initialise second KYO bind"

    bind_id="$(jq -r '.bind_id // empty' <<<"${begin}")"
    [[ -n "${bind_id}" ]] ||
        harness_fail "Second KYO bind returned no bind_id"

    code_a="$(extract_kyo_code "${A_CRT}" "${A_KEY}")" ||
        harness_fail "Cannot obtain Hospital A KYO code"

    code_b="$(extract_kyo_code "${B_CRT}" "${B_KEY}")" ||
        harness_fail "Cannot obtain Hospital B KYO code"

    approve_a="$(
        hub_post \
            /administration/kyo/hospital-a/approve \
            "$(
                jq -nc \
                    --arg b "${bind_id}" \
                    --arg c "${code_a}" \
                    '{bind_id:$b,code:$c}'
            )"
    )" || harness_fail "Hospital A KYO approval failed"

    jq -e '.approval.state == "PENDING"' <<<"${approve_a}" >/dev/null ||
        harness_fail "Hospital A did not leave second bind PENDING"

    approve_b="$(
        hub_post \
            /administration/kyo/hospital-b/approve \
            "$(
                jq -nc \
                    --arg b "${bind_id}" \
                    --arg c "${code_b}" \
                    '{bind_id:$b,code:$c}'
            )"
    )" || harness_fail "Hospital B KYO approval failed"

    candidate="$(
        jq -r '.approval.envelope_id // empty' <<<"${approve_b}"
    )"

    [[ -n "${candidate}" ]] ||
        harness_fail "Second KYO approval produced no envelope"

    printf '%s\n' "${candidate}" >"${E2_CACHE}"
    printf '%s' "${candidate}"
}

active_envelope_exists() {
    local envelope="$1"
    verifier_curl \
        "${HUB_CRT}" "${HUB_KEY}" \
        "https://${VERIFIER_HOST}:${VERIFIER_PORT}/status?state=ACTIVE" |
        jq -e \
            --arg e "${envelope}" \
            '[.envelopes[] | select(.envelope_id == $e)] | length == 1' \
            >/dev/null
}

section "1. Verify E1 is the current operational envelope"

BOUNDARY="$(hub_get /administration/boundary)" ||
    harness_fail "Cannot read Hub boundary"

jq -e \
    --arg e "${E1}" '
      .selected_envelope_id == $e
      and (
        [.envelopes[]
         | select(.envelope_id == $e and .bound == true)]
        | length == 1
      )
    ' <<<"${BOUNDARY}" >/dev/null ||
    harness_fail "E1 ${E1} is not selected and bound"

active_envelope_exists "${E1}" ||
    harness_fail "E1 is not ACTIVE at the verifier"

pass "E1 is ACTIVE, selected, and bound"

section "2. Mint real Audrey authority under E1"

MEMBERS="$(
    issuer_curl \
        "https://${ISSUER_HOST}:${ISSUER_PORT}/members"
)" || harness_fail "Cannot query Hospital A issuer members"

jq -e \
    --arg sub "${SUBJECT}" \
    '[.members[] | select(.sub == $sub)] | length == 1' \
    <<<"${MEMBERS}" >/dev/null ||
    harness_fail "${SUBJECT} is not enrolled with Hospital A"

MINT_NONCE="a8-mint-nonce-$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(12))
PY
)"
MINT_JTI="a8-mint-jti-$(python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
)"

MINT_DPOP="$(
    python3 "${MAKE_DPOP}" \
        "${HOLDER_PRIV_HEX}" \
        "${HOLDER_PUB_B64}" \
        "${MINT_NONCE}" \
        "${MINT_JTI}" \
        POST \
        "${MINT_PROOF_HTU}" \
        "${E1}"
)" || harness_fail "Could not produce ${SUBJECT} holder mint proof"

MINT="$(
    issuer_curl \
        -H 'content-type: application/json' \
        -d "$(
            jq -nc \
                --arg sub "${SUBJECT}" \
                --arg e "${E1}" \
                --arg dpop "${MINT_DPOP}" \
                '{sub:$sub,envelope_id:$e,holder_dpop:$dpop}'
        )" \
        "https://${ISSUER_HOST}:${ISSUER_PORT}/mint"
)" || harness_fail "Issuer mint failed for E1"

ECT="$(jq -r '.ect // empty' <<<"${MINT}")"
[[ -n "${ECT}" && "${ECT}" == *.*.* ]] ||
    harness_fail "Issuer returned no compact ECT"

pass "${SUBJECT} received a live ECT constituted under E1"

section "3. Control — ECT(E1) authorizes the E1 operation"

JTI_PRE="a8-e1-control-$(python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
)"

SIGN_PRE="$(sign_dpop "${E1}" "${JTI_PRE}")" ||
    harness_fail "Could not request E1 control DPoP"

jq -e '.http_status == 200 and (.body.dpop | type == "string")' \
    <<<"${SIGN_PRE}" >/dev/null || {
        printf '%s\n' "${SIGN_PRE}" | jq . >&2
        harness_fail "local holder proof generation did not produce E1 control DPoP"
    }

DPOP_PRE="$(jq -r '.body.dpop' <<<"${SIGN_PRE}")"
NONCE_PRE="$(jq -r '.body.nonce // empty' <<<"${SIGN_PRE}")"
[[ -n "${NONCE_PRE}" ]] ||
    harness_fail "Local holder proof generation produced no E1 control nonce"

PRE_FILE="${TMP}/e1-control.json"
admit_request \
    "${ECT}" "${DPOP_PRE}" "${NONCE_PRE}" "${JTI_PRE}" "${E1}" "${PRE_FILE}"

jq -e '.allow == true' "${PRE_FILE}" >/dev/null || {
    cat "${PRE_FILE}" | jq . >&2
    harness_fail "ECT(E1) failed its positive E1 control"
}

PRE_DECISION="$(jq -r '.decision_id // empty' "${PRE_FILE}")"
pass "ECT(E1) is live and authorizes the exact E1 request"

section "4. Create or reuse a distinct legitimate envelope E2"

if [[ -s "${E2_CACHE}" ]]; then
    CACHED_E2="$(tr -d '\r\n' <"${E2_CACHE}")"
else
    CACHED_E2=""
fi

if [[ -n "${CACHED_E2}" \
   && "${CACHED_E2}" != "${E1}" ]] \
   && active_envelope_exists "${CACHED_E2}"; then
    E2="${CACHED_E2}"
    note "Reusing cached A8 envelope ${E2}"
else
    E2="$(create_e2)"
    [[ "${E2}" != "${E1}" ]] ||
        harness_fail "Generated E2 unexpectedly equals E1"
    active_envelope_exists "${E2}" ||
        harness_fail "Generated E2 is not ACTIVE"
    note "Created fresh A8 envelope ${E2}"
fi

active_envelope_exists "${E1}" ||
    harness_fail "E1 ceased to be ACTIVE before cross-envelope attack"
active_envelope_exists "${E2}" ||
    harness_fail "E2 is not ACTIVE before cross-envelope attack"

pass "E1 and E2 are distinct, legitimate ACTIVE federation envelopes"

section "5. Attack — use ECT(E1) for an E2-governed operation"

JTI_CROSS="a8-cross-$(python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
)"

# Deliberately make the proof and requested operation coherent with E2.
# The only foreign authority object is the ECT, which remains the real E1 ECT.
SIGN_CROSS="$(sign_dpop "${E2}" "${JTI_CROSS}")" ||
    harness_fail "Could not request E2 DPoP for cross-envelope attack"

jq -e '.http_status == 200 and (.body.dpop | type == "string")' \
    <<<"${SIGN_CROSS}" >/dev/null || {
        printf '%s\n' "${SIGN_CROSS}" | jq . >&2
        harness_fail "local holder proof generation did not produce E2 DPoP"
    }

DPOP_CROSS="$(jq -r '.body.dpop' <<<"${SIGN_CROSS}")"
NONCE_CROSS="$(jq -r '.body.nonce // empty' <<<"${SIGN_CROSS}")"
[[ -n "${NONCE_CROSS}" ]] ||
    harness_fail "Local holder proof generation produced no E2 attack nonce"

CROSS_FILE="${TMP}/cross-envelope.json"
admit_request \
    "${ECT}" "${DPOP_CROSS}" "${NONCE_CROSS}" "${JTI_CROSS}" "${E2}" "${CROSS_FILE}"

printf '\nEvidence:\n'
jq -n \
    --arg e1 "${E1}" \
    --arg e2 "${E2}" \
    --arg pre "${PRE_DECISION}" \
    --argjson control "$(cat "${PRE_FILE}")" \
    --argjson cross "$(cat "${CROSS_FILE}")" '
    {
      ect_constituted_under: $e1,
      attempted_governance_context: $e2,
      e1_control_decision_id: $pre,
      e1_control: $control,
      cross_envelope_attempt: $cross
    }'

if jq -e '.allow == true' "${CROSS_FILE}" >/dev/null; then
    confirmed \
"Gatekeeper accepted ECT(E1) for an operation governed by E2."
fi

CROSS_REASON="$(jq -r '.reason // "unspecified"' "${CROSS_FILE}")"

if [[ "${CROSS_REASON}" != "envelope_mismatch" ]]; then
    cat "${CROSS_FILE}" | jq . >&2
    harness_fail \
"Cross-envelope request was denied for ${CROSS_REASON}, not envelope_mismatch; A8 invariant was not isolated."
fi

protected \
"Gatekeeper rejected ECT(E1) at the E2 boundary with envelope_mismatch."
