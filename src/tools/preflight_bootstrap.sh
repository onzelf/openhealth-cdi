#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CERT_DIR="${SRC_DIR}/vfp-governance/verifier/certs"

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

echo
echo "BOOTSTRAP PREFLIGHT: PASS"
echo "Safe to run tofu apply."
