#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CERT_DIR="${SRC_DIR}/vfp-governance/verifier/certs"
REPO_ROOT="$(cd "${SRC_DIR}/.." && pwd)"
HOLDER_KEYS_DIR="${SRC_DIR}/vfp-governance/verifier/vault/holder_keys"
GEN_MEMBER_KEYS="${SRC_DIR}/tools/gen_member_keys.py"
OPENAI_ENV_FILE="${REPO_ROOT}/secrets/.env"

echo "OpenHealth CDI bootstrap preflight"
echo "cert directory: ${CERT_DIR}"
echo

[[ -d "${CERT_DIR}" ]] || {
    echo "FAIL: certificate directory does not exist: ${CERT_DIR}" >&2
    echo "Run src/tools/make_certs.sh first." >&2
    exit 1
}

required_files=(
    ca.crt
    verifier.crt
    verifier.key
    hub.crt
    hub.key
    HospitalA-admin.crt
    HospitalA-admin.key
    HospitalB-admin.crt
    HospitalB-admin.key
    issuer-proxy.crt
    issuer-proxy.key
    fcac-evidence.key
    fcac-evidence.pub
)

failed=0

for file in "${required_files[@]}"; do
    path="${CERT_DIR}/${file}"

    if [[ -d "${path}" ]]; then
        echo "FAIL: ${file} is a directory, expected a regular file"
        failed=1
    elif [[ ! -f "${path}" ]]; then
        echo "FAIL: missing ${file}"
        failed=1
    elif [[ ! -s "${path}" ]]; then
        echo "FAIL: empty ${file}"
        failed=1
    else
        echo "OK:   ${file}"
    fi
done

if (( failed )); then
    echo
    echo "BOOTSTRAP PREFLIGHT: FAIL"
    echo "Do not run tofu apply."
    exit 1
fi

# Verify that the evidence key pair is internally consistent.
evidence_private="${CERT_DIR}/fcac-evidence.key"
evidence_public="${CERT_DIR}/fcac-evidence.pub"

derived_public="$(mktemp)"
trap 'rm -f "${derived_public}"' EXIT

openssl pkey \
    -in "${evidence_private}" \
    -pubout \
    -out "${derived_public}" \
    >/dev/null 2>&1 || {
        echo "FAIL: cannot derive public key from fcac-evidence.key" >&2
        exit 1
    }

cmp -s "${derived_public}" "${evidence_public}" || {
    echo "FAIL: fcac-evidence.key and fcac-evidence.pub do not match" >&2
    exit 1
}

echo "OK:   FCaC evidence key pair matches"

# ------------------------------------------------------------------
# Runtime holder identities
# ------------------------------------------------------------------

mkdir -p "${HOLDER_KEYS_DIR}" || {
    echo "FAIL: cannot create holder-key directory: ${HOLDER_KEYS_DIR}" >&2
    exit 1
}

if [[ ! -w "${HOLDER_KEYS_DIR}" ]]; then
    echo "FAIL: holder-key directory is not writable: ${HOLDER_KEYS_DIR}" >&2
    echo "Repair ownership before running tofu apply." >&2
    exit 1
fi

chmod 700 "${HOLDER_KEYS_DIR}"

provision_holder() {
    local who="$1"
    local org="$2"
    local private_key="${HOLDER_KEYS_DIR}/${who}.privhex"

    if [[ ! -s "${private_key}" ]]; then
        (
            umask 077
            python3 "${GEN_MEMBER_KEYS}" \
                --generate \
                --who "${who}" \
                --org "${org}" \
                --output-dir "${HOLDER_KEYS_DIR}" \
                >/dev/null
        ) || {
            echo "FAIL: unable to provision holder identity for ${who}" >&2
            exit 1
        }
        echo "OK:   provisioned holder identity for ${who}"
    else
        echo "OK:   holder identity exists for ${who}"
    fi

    python3 "${GEN_MEMBER_KEYS}" \
        --derive \
        --private-key "${private_key}" \
        --format json \
        >/dev/null || {
            echo "FAIL: invalid holder private key for ${who}" >&2
            exit 1
        }
}

provision_holder "Audrey"  "org://HospitalA"
provision_holder "Bob"     "org://HospitalB"
provision_holder "Charlie" "org://HospitalA"

# ------------------------------------------------------------------
# Hal reasoning secret
# ------------------------------------------------------------------

if [[ -d "${OPENAI_ENV_FILE}" ]]; then
    echo "FAIL: ${OPENAI_ENV_FILE} is a directory, expected a regular file" >&2
    echo "Remove it and create the OpenAI secret file before tofu apply." >&2
    exit 1
fi

if [[ ! -s "${OPENAI_ENV_FILE}" ]]; then
    echo "FAIL: missing or empty OpenAI secret file: ${OPENAI_ENV_FILE}" >&2
    echo "Create it with OPENAI_API_KEY=<key> before tofu apply." >&2
    exit 1
fi

if ! grep -qE '^OPENAI_API_KEY=.+$' "${OPENAI_ENV_FILE}"; then
    echo "FAIL: OPENAI_API_KEY is missing or empty in ${OPENAI_ENV_FILE}" >&2
    exit 1
fi

echo "OK:   OpenAI secret file"

# ------------------------------------------------------------------
# Stable verifier logical identity
# ------------------------------------------------------------------

if ! getent hosts verifier.local >/dev/null 2>&1; then
    echo "FAIL: verifier.local does not resolve on this host" >&2
    echo "Configure host resolution before tofu apply." >&2
    echo "For a single-host deployment, for example:" >&2
    echo "  127.0.0.1 verifier.local" >&2
    exit 1
fi
echo "OK:   verifier.local resolves"

echo
echo "BOOTSTRAP PREFLIGHT: PASS"
echo "Safe to run tofu apply."
