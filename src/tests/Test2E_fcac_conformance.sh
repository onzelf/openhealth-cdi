#!/usr/bin/env bash
# Test2E_fcac_conformance.sh
#
# Iteration 4 conformance smoke test.
# Phase 1 validates canonical envelope-policy binding.
# Phase 2 validates independently verifiable signed envelopes and signed
# Gatekeeper ALLOW/DENY decision records.
#
# Usage
#   ISSUER_IP=<host-ip> ./Test2E_fcac_conformance.sh <active-envelope-id>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENVELOPE_ID="${1:-}"
[[ -n "${ENVELOPE_ID}" ]] || {
    printf 'Usage: %s <active-envelope-id>\n' "$0" >&2
    exit 1
}

GATEKEEPER_FILE="${SRC_DIR}/vfp-governance/gatekeeper/app.py"
POLICY_FILE="${SRC_DIR}/vfp-governance/verifier/state/policy.json"
ENVELOPE_FILE="${SRC_DIR}/vfp-governance/verifier/state/envelopes/${ENVELOPE_ID}.json"
DECISIONS_DIR="${SRC_DIR}/vfp-governance/verifier/state/events/decisions"
EVIDENCE_PUBLIC_KEY="${SRC_DIR}/vfp-governance/verifier/certs/fcac-evidence.pub"
EVIDENCE_VERIFIER="${SRC_DIR}/tools/verify_fcac_evidence.py"
EVIDENCE_KEY_KID="${EVIDENCE_KEY_KID:-fcac-evidence-key-1}"

ISSUER_HOST="${ISSUER_HOST:-issuer-hospitala.local}"
ISSUER_PORT="${ISSUER_PORT:-9443}"
ISSUER_IP="${ISSUER_IP:-}"
ISSUER_URL="https://${ISSUER_HOST}:${ISSUER_PORT}"
SUBJECT="${SUBJECT:-Audrey}"
RUN_ID="${RUN_ID:-local-pathmnist-ab-001}"
VERIFIER_URL="${VERIFIER_URL:-https://verifier.local:8443}"
DPOP_HTU="${DPOP_HTU:-https://verifier.local/admission/check}"
ALLOW_TISSUE="${ALLOW_TISSUE:-mucus}"
DENY_TISSUE="${DENY_TISSUE:-cancer_associated_stroma}"

HOLDER_PRIVATE="${HOLDER_PRIVATE:-${SRC_DIR}/vfp-governance/verifier/vault/holder_keys/${SUBJECT}.privhex}"
GEN_MEMBER_KEYS="${SRC_DIR}/tools/gen_member_keys.py"
MAKE_DPOP="${SRC_DIR}/tools/make_dpop_jwt_eddsa.py"

CAC="${SRC_DIR}/vfp-governance/verifier/certs/ca.crt"
CLIENT_CRT="${CLIENT_CRT:-${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.crt}"
CLIENT_KEY="${CLIENT_KEY:-${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.key}"
HUB_CRT="${HUB_CRT:-${SRC_DIR}/vfp-governance/verifier/certs/hub.crt}"
HUB_KEY="${HUB_KEY:-${SRC_DIR}/vfp-governance/verifier/certs/hub.key}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

pass() {
    printf '\033[32m✓\033[0m %s\n' "$*"
}

fail() {
    printf '\033[31m✗\033[0m %s\n' "$*" >&2
    exit 1
}

section() {
    printf '\n\033[1m== %s ==\033[0m\n' "$*"
}

require_file() {
    [[ -s "$1" ]] || fail "Missing or empty file: $1"
}

for command_name in curl jq python3 grep openssl; do
    command -v "${command_name}" >/dev/null 2>&1 ||
        fail "Missing command: ${command_name}"
done

for path in \
    "${GATEKEEPER_FILE}" \
    "${POLICY_FILE}" \
    "${ENVELOPE_FILE}" \
    "${EVIDENCE_PUBLIC_KEY}" \
    "${EVIDENCE_VERIFIER}" \
    "${GEN_MEMBER_KEYS}" \
    "${MAKE_DPOP}" \
    "${HOLDER_PRIVATE}" \
    "${CAC}" \
    "${CLIENT_CRT}" \
    "${CLIENT_KEY}" \
    "${HUB_CRT}" \
    "${HUB_KEY}"; do
    require_file "${path}"
done

section "1. Static Fix 1 boundary"

grep -q 'ph = _policy_hash' "${GATEKEEPER_FILE}" ||
    fail "Bind creation does not use the Gatekeeper canonical policy hash"

grep -q 'envelope = load_active_envelope(body.envelope_id)' "${GATEKEEPER_FILE}" ||
    fail "Admission does not reload the active envelope"

grep -q 'ect_envelope_policy_mismatch' "${GATEKEEPER_FILE}" ||
    fail "Admission does not reject ECT-to-envelope policy mismatch"

grep -q 'ect_exp_exceeds_envelope' "${GATEKEEPER_FILE}" ||
    fail "Admission does not reject an overlong ECT"

if grep -q '"sha256:" + hashlib.sha256' "${GATEKEEPER_FILE}"; then
    fail "Legacy non-canonical envelope policy hashing remains"
fi

grep -q 'env = sign_artifact(env)' "${GATEKEEPER_FILE}" ||
    fail "Envelope creation does not sign the stored envelope"

grep -q 'verify_artifact(envelope, "fcac_envelope")' "${GATEKEEPER_FILE}" ||
    fail "Admission does not verify the stored envelope signature"

grep -q 'emit_decision_record' "${GATEKEEPER_FILE}" ||
    fail "Gatekeeper decision-record emission is absent"

grep -q 'persist_record_ms' "${GATEKEEPER_FILE}" ||
    fail "Benchmark does not expose evidence persistence latency"

pass "Canonical binding and signed-evidence checks are present"

section "2. Envelope state and canonical policy hash"

ENVELOPE_STATE="$(jq -r '.state // empty' "${ENVELOPE_FILE}")"
ENVELOPE_EXP="$(jq -r '.valid_until // .exp // empty' "${ENVELOPE_FILE}")"
ENVELOPE_POLICY_HASH="$(jq -r '.policy_hash // empty' "${ENVELOPE_FILE}")"

[[ "${ENVELOPE_STATE}" == "ACTIVE" ]] ||
    fail "Envelope state is ${ENVELOPE_STATE:-missing}, expected ACTIVE"
[[ "${ENVELOPE_EXP}" =~ ^[0-9]+$ ]] ||
    fail "Envelope expiry is missing or invalid"
(( ENVELOPE_EXP > $(date +%s) )) ||
    fail "Envelope is expired"
[[ -n "${ENVELOPE_POLICY_HASH}" ]] ||
    fail "Envelope policy_hash is missing"

CANONICAL_POLICY_HASH="$(python3 - "${POLICY_FILE}" <<'PY'
import base64
import hashlib
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as stream:
    policy = json.load(stream)
canonical = json.dumps(
    policy,
    sort_keys=True,
    separators=(",", ":"),
    ensure_ascii=False,
).encode("utf-8")
digest = hashlib.sha256(canonical).digest()
print(base64.urlsafe_b64encode(digest).decode("ascii").rstrip("="))
PY
)"

[[ "${ENVELOPE_POLICY_HASH}" == "${CANONICAL_POLICY_HASH}" ]] ||
    fail "Envelope policy hash does not match canonical policy.json"

python3 "${EVIDENCE_VERIFIER}" \
    --public-key "${EVIDENCE_PUBLIC_KEY}" \
    --artifact "${ENVELOPE_FILE}" \
    --expected-type fcac_envelope \
    --expected-kid "${EVIDENCE_KEY_KID}" \
    | jq .

jq -e '.evidence.pubkey == null' "${ENVELOPE_FILE}" >/dev/null ||
    fail "Envelope embeds its own verification key"

pass "Envelope is ACTIVE, canonical-policy-bound, and independently verifiable"

section "3. Mint an envelope-bounded ECT"

NBF="$(date -u -Iseconds -d '-60 seconds' | sed 's/+00:00/Z/')"
# Deliberately request a validity period longer than the envelope.
# The Gatekeeper must attenuate exp to the envelope boundary.
EXP="$(date -u -Iseconds -d '+24 hours' | sed 's/+00:00/Z/')"

MINT_REQUEST="$(
    jq -nc \
        --arg sub "${SUBJECT}" \
        --arg envelope "${ENVELOPE_ID}" \
        --arg nbf "${NBF}" \
        --arg exp "${EXP}" \
        '{sub: $sub, envelope_id: $envelope, nbf: $nbf, exp: $exp}'
)"

CURL_ISSUER=(
    -sS
    --cacert "${CAC}"
    --cert "${CLIENT_CRT}"
    --key "${CLIENT_KEY}"
)
if [[ -n "${ISSUER_IP}" ]]; then
    CURL_ISSUER+=(--resolve "${ISSUER_HOST}:${ISSUER_PORT}:${ISSUER_IP}")
fi

HOLDER_IDENTITY=""
if ! HOLDER_IDENTITY="$(
    python3 "${GEN_MEMBER_KEYS}" \
        --derive \
        --private-key "${HOLDER_PRIVATE}" \
        --format json
)"; then
    fail "Unable to derive ${SUBJECT} holder identity"
fi

HOLDER_PUB_B64="$(jq -er '.pub_b64' <<<"${HOLDER_IDENTITY}")" ||
    fail "Derived holder identity does not contain pub_b64"
HOLDER_JKT="$(jq -er '.jkt' <<<"${HOLDER_IDENTITY}")" ||
    fail "Derived holder identity does not contain jkt"
HOLDER_PRIV_HEX="$(tr -d '\r\n' <"${HOLDER_PRIVATE}")"

MEMBERS_FILE="${TMP_DIR}/members.json"
MEMBERS_STATUS="$(
    curl "${CURL_ISSUER[@]}" \
        -o "${MEMBERS_FILE}" \
        -w '%{http_code}' \
        "${ISSUER_URL}/members"
)"

if [[ "${MEMBERS_STATUS}" != "200" ]]; then
    cat "${MEMBERS_FILE}" >&2
    fail "Issuer member lookup returned HTTP ${MEMBERS_STATUS}"
fi

ENROLLED_MEMBER_COUNT="$(
    jq -r \
        --arg sub "${SUBJECT}" \
        '[.members[] | select(.sub == $sub)] | length' \
        "${MEMBERS_FILE}"
)"
[[ "${ENROLLED_MEMBER_COUNT}" == "1" ]] ||
    fail "Issuer registry contains ${ENROLLED_MEMBER_COUNT} records for ${SUBJECT}, expected 1"

ENROLLED_PUB_B64="$(
    jq -er \
        --arg sub "${SUBJECT}" \
        '.members[] | select(.sub == $sub) | .pub_b64' \
        "${MEMBERS_FILE}"
)" || fail "Issuer enrollment for ${SUBJECT} does not contain pub_b64"

ENROLLED_JKT="$(
    jq -er \
        --arg sub "${SUBJECT}" \
        '.members[] | select(.sub == $sub) | .jkt' \
        "${MEMBERS_FILE}"
)" || fail "Issuer enrollment for ${SUBJECT} does not contain jkt"

[[ "${HOLDER_PUB_B64}" == "${ENROLLED_PUB_B64}" ]] ||
    fail "${SUBJECT} private key does not match the issuer-enrolled public key"
[[ "${HOLDER_JKT}" == "${ENROLLED_JKT}" ]] ||
    fail "${SUBJECT} private key does not match the issuer-enrolled JWK thumbprint"

pass "Existing holder custody matches the prior issuer enrollment"

MINT_FILE="${TMP_DIR}/mint.json"
MINT_STATUS="$(
    curl "${CURL_ISSUER[@]}" \
        -o "${MINT_FILE}" \
        -w '%{http_code}' \
        -X POST \
        "${ISSUER_URL}/mint" \
        -H 'content-type: application/json' \
        -d "${MINT_REQUEST}"
)"

if [[ "${MINT_STATUS}" != "200" ]]; then
    cat "${MINT_FILE}" >&2
    fail "Issuer mint returned HTTP ${MINT_STATUS}"
fi

ECT="$(jq -r '.ect // empty' "${MINT_FILE}")"
[[ -n "${ECT}" ]] || fail "Issuer did not return an ECT"

CLAIMS_FILE="${TMP_DIR}/claims.json"
python3 - "${ECT}" "${CLAIMS_FILE}" <<'PY'
import base64
import json
import sys

token, output_path = sys.argv[1], sys.argv[2]
parts = token.split(".")
if len(parts) != 3:
    raise SystemExit("ECT is not a compact JWS")
payload = parts[1] + "=" * ((4 - len(parts[1]) % 4) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload).decode("utf-8"))
with open(output_path, "w", encoding="utf-8") as stream:
    json.dump(claims, stream, indent=2, sort_keys=True)
PY

ECT_ENVELOPE_ID="$(jq -r '.envelope_id // empty' "${CLAIMS_FILE}")"
ECT_POLICY_HASH="$(jq -r '.policy.policy_hash // empty' "${CLAIMS_FILE}")"
ECT_EXP="$(jq -r '.exp // empty' "${CLAIMS_FILE}")"

[[ "${ECT_ENVELOPE_ID}" == "${ENVELOPE_ID}" ]] ||
    fail "ECT envelope_id does not match the requested envelope"
[[ "${ECT_POLICY_HASH}" == "${ENVELOPE_POLICY_HASH}" ]] ||
    fail "ECT policy hash does not match the envelope"
[[ "${ECT_EXP}" =~ ^[0-9]+$ ]] ||
    fail "ECT expiry is missing or invalid"
(( ECT_EXP <= ENVELOPE_EXP )) ||
    fail "ECT expiry exceeds the envelope expiry"

pass "ECT is envelope-bound, policy-bound, and time-bounded"

section "4. Signed ALLOW and DENY decision evidence"

CURL_HUB=(
    -sS
    --cacert "${CAC}"
    --cert "${HUB_CRT}"
    --key "${HUB_KEY}"
)

run_decision_case() {
    local label="$1"
    local tissue="$2"
    local expected_allow="$3"
    local expected_reason="$4"

    local nonce="nonce-$(date +%s%N)"
    local jti="jti-$(date +%s%N)"
    local dpop
    local request_body
    local response_file="${TMP_DIR}/${label}.json"
    local status
    local actual_allow
    local actual_reason
    local decision_id
    local record_path

    dpop="$(
        python3 "${MAKE_DPOP}" \
            "${HOLDER_PRIV_HEX}" \
            "${HOLDER_PUB_B64}" \
            "${nonce}" \
            "${jti}" \
            POST \
            "${DPOP_HTU}" \
            "${ENVELOPE_ID}"
    )"

    request_body="$(
        jq -nc \
            --arg envelope "${ENVELOPE_ID}" \
            --arg run "${RUN_ID}" \
            --arg tissue "${tissue}" \
            --arg jti "${jti}" \
            '{
                envelope_id: $envelope,
                run_id: $run,
                resource: "pathmnist-colon-pathology",
                action: "query_model",
                purpose: "approved_model_query",
                requested_tissues: [$tissue],
                jti: $jti
            }'
    )"

    status="$(
        curl "${CURL_HUB[@]}" \
            -o "${response_file}" \
            -w '%{http_code}' \
            -X POST \
            "${VERIFIER_URL}/admission/check" \
            -H "Authorization: ECT ${ECT}" \
            -H "DPoP: ${dpop}" \
            -H "X-DPoP-Nonce: ${nonce}" \
            -H 'content-type: application/json' \
            -d "${request_body}"
    )"

    [[ "${status}" == "200" ]] || {
        cat "${response_file}" >&2
        fail "${label} returned HTTP ${status}"
    }

    actual_allow="$(jq -r '.allow' "${response_file}")"
    actual_reason="$(jq -r '.reason // ""' "${response_file}")"
    decision_id="$(jq -r '.decision_id // empty' "${response_file}")"

    if [[ "${actual_allow}" != "${expected_allow}" ]]; then
        jq . "${response_file}" >&2
        fail "${label} expected allow=${expected_allow}, got ${actual_allow}"
    fi
    if [[ -n "${expected_reason}" ]] &&
        [[ "${actual_reason}" != "${expected_reason}" ]]; then
        jq . "${response_file}" >&2
        fail "${label} expected reason=${expected_reason}, got ${actual_reason}"
    fi
    [[ -n "${decision_id}" ]] ||
        fail "${label} response does not carry decision_id"

    record_path="${DECISIONS_DIR}/${decision_id}.json"
    require_file "${record_path}"

    python3 "${EVIDENCE_VERIFIER}" \
        --public-key "${EVIDENCE_PUBLIC_KEY}" \
        --artifact "${record_path}" \
        --expected-type fcac_admission_decision \
        --expected-kid "${EVIDENCE_KEY_KID}" \
        | jq .

    jq -e \
        --arg decision "${decision_id}" \
        --arg policy "${CANONICAL_POLICY_HASH}" \
        --arg envelope "${ENVELOPE_ID}" \
        --arg run "${RUN_ID}" \
        --arg tissue "${tissue}" \
        --arg expected "$(
            [[ "${expected_allow}" == "true" ]] && printf ALLOW || printf DENY
        )" \
        '
        .decision_id == $decision
        and .policy_hash == $policy
        and .approved_research_collaboration == $envelope
        and .related_model_run_when_applicable == $run
        and .requested_action == "query_model"
        and .requested_purpose == "approved_model_query"
        and .requested_tissue_classes == [$tissue]
        and .allow_or_deny == $expected
        and (.timestamp | type == "number")
        and (.requester_binding_result | type == "string")
        and (.evidence.signature | type == "string" and length > 0)
        and .evidence.pubkey == null
        ' "${record_path}" >/dev/null ||
        fail "${label} signed decision record is incomplete"

    pass "${label} produced independently verifiable ${expected_allow} evidence"
}

run_decision_case \
    allow \
    "${ALLOW_TISSUE}" \
    true \
    ""

run_decision_case \
    deny \
    "${DENY_TISSUE}" \
    false \
    capability_scope_exceeded

pass "Gatekeeper produced signed ALLOW and DENY decision records"

printf '\n'
pass "Test2E Phases 1+2 passed: binding and signed evidence are operational"
