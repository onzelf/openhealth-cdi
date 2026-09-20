#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENROLLMENT_FILE="${1:-}"
ISSUER_IP="${ISSUER_IP:-127.0.0.1}"
ISSUER_PORT="${ISSUER_PORT:-9443}"

[[ -n "${ENROLLMENT_FILE}" && -s "${ENROLLMENT_FILE}" ]] || {
  echo "Usage: $0 <holder-enrollment.json>" >&2
  exit 1
}

for command_name in curl jq; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "Missing command: ${command_name}" >&2
    exit 1
  }
done

ORG_ID="$(jq -er '.org_id' "${ENROLLMENT_FILE}")"
SUBJECT="$(jq -er '.sub' "${ENROLLMENT_FILE}")"

case "${ORG_ID}" in
  "org://HospitalA")
    ISSUER_HOST="issuer-hospitala.local"
    ADMIN_CRT="${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.crt"
    ADMIN_KEY="${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.key"
    ;;
  "org://HospitalB")
    ISSUER_HOST="issuer-hospitalb.local"
    ADMIN_CRT="${SRC_DIR}/vfp-governance/verifier/certs/HospitalB-admin.crt"
    ADMIN_KEY="${SRC_DIR}/vfp-governance/verifier/certs/HospitalB-admin.key"
    ;;
  *)
    echo "Unsupported org_id: ${ORG_ID}" >&2
    exit 1
    ;;
esac

CA="${SRC_DIR}/vfp-governance/verifier/certs/ca.crt"
for path in "${CA}" "${ADMIN_CRT}" "${ADMIN_KEY}"; do
  [[ -s "${path}" ]] || {
    echo "Missing file: ${path}" >&2
    exit 1
  }
done

ISSUER_URL="https://${ISSUER_HOST}:${ISSUER_PORT}"
TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT

STATUS="$(
  curl -sS \
    --cacert "${CA}" \
    --cert "${ADMIN_CRT}" \
    --key "${ADMIN_KEY}" \
    --resolve "${ISSUER_HOST}:${ISSUER_PORT}:${ISSUER_IP}" \
    -H 'content-type: application/json' \
    --data-binary "@${ENROLLMENT_FILE}" \
    -o "${TMP}" \
    -w '%{http_code}' \
    "${ISSUER_URL}/members/rotate"
)"

cat "${TMP}" | jq .

[[ "${STATUS}" == "200" ]] || {
  echo "Holder key rotation failed: HTTP ${STATUS}" >&2
  exit 1
}

printf 'Rotated %s under %s\n' "${SUBJECT}" "${ORG_ID}"
