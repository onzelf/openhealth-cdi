#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ISSUER_IP="${1:-127.0.0.1}"
ISSUER_PORT="${ISSUER_PORT:-9443}"

HOLDER_KEYS_DIR="${SRC_DIR}/../secrets/holder_keys"
GEN_MEMBER_KEYS="${SRC_DIR}/tools/gen_member_keys.py"

CAC="${SRC_DIR}/vfp-governance/verifier/certs/ca.crt"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

pass() { printf '\033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

for command_name in curl jq python3; do
    command -v "${command_name}" >/dev/null 2>&1 \
        || fail "Missing command: ${command_name}"
done

[[ -s "${CAC}" ]] || fail "Missing CA certificate: ${CAC}"

enroll_member() {
    local subject="$1"
    local org="$2"
    local issuer_host="$3"
    local client_crt="$4"
    local client_key="$5"

    local private_key="${HOLDER_KEYS_DIR}/${subject}.privhex"
    local issuer_url="https://${issuer_host}:${ISSUER_PORT}"

    [[ -s "${private_key}" ]] \
        || fail "Missing holder key for ${subject}: ${private_key}"

    [[ -s "${client_crt}" ]] \
        || fail "Missing issuer admin certificate: ${client_crt}"

    [[ -s "${client_key}" ]] \
        || fail "Missing issuer admin key: ${client_key}"

    local identity
    identity="$(
        python3 "${GEN_MEMBER_KEYS}" \
            --derive \
            --private-key "${private_key}" \
            --format json
    )" || fail "Unable to derive holder identity for ${subject}"

    local pub_b64
    local jkt

    pub_b64="$(jq -er '.pub_b64' <<<"${identity}")"
    jkt="$(jq -er '.jkt' <<<"${identity}")"

    local members_file="${TMP_DIR}/${subject}-members.json"
    local status

    status="$(
        curl -sS \
            --cacert "${CAC}" \
            --cert "${client_crt}" \
            --key "${client_key}" \
            --resolve "${issuer_host}:${ISSUER_PORT}:${ISSUER_IP}" \
            -o "${members_file}" \
            -w '%{http_code}' \
            "${issuer_url}/members"
    )"

    [[ "${status}" == "200" ]] || {
        cat "${members_file}" >&2
        fail "${issuer_host} /members returned HTTP ${status}"
    }

    local count
    count="$(
        jq -r \
            --arg sub "${subject}" \
            '[.members[] | select(.sub == $sub)] | length' \
            "${members_file}"
    )"

    if [[ "${count}" == "0" ]]; then
        local request
        request="$(
            jq -nc \
                --arg org "${org}" \
                --arg sub "${subject}" \
                --arg pub "${pub_b64}" \
                --arg jkt "${jkt}" \
                '{
                    org_id: $org,
                    member_id: $sub,
                    sub: $sub,
                    pub_b64: $pub,
                    jkt: $jkt
                }'
        )"

        local register_file="${TMP_DIR}/${subject}-register.json"

        status="$(
            curl -sS \
                --cacert "${CAC}" \
                --cert "${client_crt}" \
                --key "${client_key}" \
                --resolve "${issuer_host}:${ISSUER_PORT}:${ISSUER_IP}" \
                -o "${register_file}" \
                -w '%{http_code}' \
                -X POST \
                -H 'content-type: application/json' \
                -d "${request}" \
                "${issuer_url}/members/register"
        )"

        [[ "${status}" == "200" ]] || {
            cat "${register_file}" >&2
            fail "${subject} registration returned HTTP ${status}"
        }

        pass "Registered ${subject} with ${org}"
        return
    fi

    [[ "${count}" == "1" ]] \
        || fail "${org} contains ${count} records for ${subject}"

    local enrolled_pub
    local enrolled_jkt

    enrolled_pub="$(
        jq -er \
            --arg sub "${subject}" \
            '.members[] | select(.sub == $sub) | .pub_b64' \
            "${members_file}"
    )"

    enrolled_jkt="$(
        jq -er \
            --arg sub "${subject}" \
            '.members[] | select(.sub == $sub) | .jkt' \
            "${members_file}"
    )"

    [[ "${enrolled_pub}" == "${pub_b64}" ]] \
        || fail "${subject} enrollment does not match canonical public key"

    [[ "${enrolled_jkt}" == "${jkt}" ]] \
        || fail "${subject} enrollment does not match canonical JKT"

    pass "${subject} enrollment already matches canonical holder identity"
}

A_CRT="${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.crt"
A_KEY="${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.key"

B_CRT="${SRC_DIR}/vfp-governance/verifier/certs/HospitalB-admin.crt"
B_KEY="${SRC_DIR}/vfp-governance/verifier/certs/HospitalB-admin.key"

echo "OpenHealth CDI member bootstrap"
echo

enroll_member \
    "Audrey" \
    "org://HospitalA" \
    "issuer-hospitala.local" \
    "${A_CRT}" \
    "${A_KEY}"

enroll_member \
    "Bob" \
    "org://HospitalB" \
    "issuer-hospitalb.local" \
    "${B_CRT}" \
    "${B_KEY}"

enroll_member \
    "Charlie" \
    "org://HospitalA" \
    "issuer-hospitala.local" \
    "${A_CRT}" \
    "${A_KEY}"

echo
echo "MEMBER BOOTSTRAP: PASS"