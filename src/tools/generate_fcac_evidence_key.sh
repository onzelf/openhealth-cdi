#!/usr/bin/env bash
# Generate the pinned Ed25519 evidence key used to sign FCaC envelopes
# and Gatekeeper admission-decision records.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CERT_DIR="${FCAC_CERT_DIR:-${SRC_DIR}/vfp-governance/verifier/certs}"

PRIVATE_KEY="${CERT_DIR}/fcac-evidence.key"
PUBLIC_KEY="${CERT_DIR}/fcac-evidence.pub"

command -v openssl >/dev/null 2>&1 || {
    echo "Missing command: openssl" >&2
    exit 1
}

mkdir -p "${CERT_DIR}"

if [[ -s "${PRIVATE_KEY}" && -s "${PUBLIC_KEY}" ]]; then
    echo "FCaC evidence key already exists"
    echo "private: ${PRIVATE_KEY}"
    echo "public:  ${PUBLIC_KEY}"
    exit 0
fi

if [[ -e "${PRIVATE_KEY}" || -e "${PUBLIC_KEY}" ]]; then
    echo "Incomplete FCaC evidence key pair in ${CERT_DIR}" >&2
    echo "Remove or repair the partial pair before retrying" >&2
    exit 1
fi

umask 077
openssl genpkey \
    -algorithm ED25519 \
    -out "${PRIVATE_KEY}"

openssl pkey \
    -in "${PRIVATE_KEY}" \
    -pubout \
    -out "${PUBLIC_KEY}"

chmod 600 "${PRIVATE_KEY}"
chmod 644 "${PUBLIC_KEY}"

echo "Generated pinned FCaC evidence key"
echo "private: ${PRIVATE_KEY}"
echo "public:  ${PUBLIC_KEY}"
openssl pkey \
    -pubin \
    -in "${PUBLIC_KEY}" \
    -outform DER \
    | openssl dgst -sha256
