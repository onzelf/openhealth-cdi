#!/usr/bin/env bash
set -euo pipefail

# Before using the containerized system, active human actors must be enrolled
# by their organizations and their private keys placed in holder-signer custody.

ACTOR_CATALOG="${ACTOR_CATALOG:-../vfp-core/issuers/config/actors.json}"
VAULT_HOLDER_KEYS_DIR="../vfp-governance/verifier/vault/holder_keys"

if [[ ! -r "${ACTOR_CATALOG}" ]]; then
  echo "Actor catalog not found: ${ACTOR_CATALOG}" >&2
  exit 1
fi

mapfile -t ACTIVE_MEMBERS < <(
  jq -r '
    to_entries[]
    | .key as $organization
    | .value[]
    | select(
        .status == "active"
        and .actor_type == "human"
      )
    | [$organization, .principal]
    | @tsv
  ' "${ACTOR_CATALOG}"
)

if (( ${#ACTIVE_MEMBERS[@]} == 0 )); then
  echo "No active human members are defined in ${ACTOR_CATALOG}" >&2
  exit 1
fi

declare -A REGISTERED_ORGANIZATIONS=()

configure_issuer() {
  local organization="$1"

  case "${organization}" in
    "org://HospitalA")
      ISSUER_HOST="issuer-hospitala.local"
      ADMIN_CERT_NAME="HospitalA-admin"
      ;;
    "org://HospitalB")
      ISSUER_HOST="issuer-hospitalb.local"
      ADMIN_CERT_NAME="HospitalB-admin"
      ;;
    *)
      echo "No demo issuer connector for active organization ${organization}" >&2
      exit 1
      ;;
  esac
}

for member in "${ACTIVE_MEMBERS[@]}"; do
  IFS=$'\t' read -r organization principal <<< "${member}"
  configure_issuer "${organization}"

  echo "------------------------->"
  echo "Register member ${principal} for ${organization}"
  python3 gen_member_keys.py --org "${organization}" --who "${principal}"

  DATA=$(jq 'del(.created_at)' "holder_keys/${principal}.register.json")
  echo "${DATA}"

  curl -vk \
    --resolve "${ISSUER_HOST}:9443:192.168.1.25" \
    --cacert ../vfp-governance/verifier/certs/ca.crt \
    --cert "../vfp-governance/verifier/certs/${ADMIN_CERT_NAME}.crt" \
    --key "../vfp-governance/verifier/certs/${ADMIN_CERT_NAME}.key" \
    -H "Content-Type: application/json" \
    --data "${DATA}" "https://${ISSUER_HOST}:9443/members/register"

  REGISTERED_ORGANIZATIONS["${organization}"]=1
done

for organization in "${!REGISTERED_ORGANIZATIONS[@]}"; do
  configure_issuer "${organization}"
  curl -sk \
    --resolve "${ISSUER_HOST}:9443:192.168.1.25" \
    --cacert ../vfp-governance/verifier/certs/ca.crt \
    --cert "../vfp-governance/verifier/certs/${ADMIN_CERT_NAME}.crt" \
    --key "../vfp-governance/verifier/certs/${ADMIN_CERT_NAME}.key" \
    "https://${ISSUER_HOST}:9443/members" | jq .
done

echo "done"
echo " "

mkdir -p "${VAULT_HOLDER_KEYS_DIR}"

# Docker creates a missing bind-mount source as root. Repair only this
# dedicated holder-key directory when it is not writable by the current user.
if [[ ! -w "${VAULT_HOLDER_KEYS_DIR}" ]]; then
  sudo chown "$(id -u):$(id -g)" "${VAULT_HOLDER_KEYS_DIR}"
fi

chmod 700 "${VAULT_HOLDER_KEYS_DIR}"

for member in "${ACTIVE_MEMBERS[@]}"; do
  IFS=$'\t' read -r _ principal <<< "${member}"
  install -v -m 600 \
    "holder_keys/${principal}.privhex" \
    "${VAULT_HOLDER_KEYS_DIR}/${principal}.privhex"
done
