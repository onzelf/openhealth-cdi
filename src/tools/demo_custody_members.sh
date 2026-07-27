#!/usr/bin/env bash
set -euo pipefail

# before using containerized system, members must be enrolled and registered by their organizations

# generate locally on disk
# -------------------------------------------------------
echo "------------------------->"
echo "(1) register member Audrey"
python3 gen_member_keys.py  --org org://HospitalA --who Audrey

DATA=$(jq 'del(.created_at)' holder_keys/Audrey.register.json)
echo $DATA

curl -vk \
  --resolve issuer-hospitala.local:9443:192.168.1.25 \
  --cacert ../vfp-governance/verifier/certs/ca.crt \
  --cert  ../vfp-governance/verifier/certs/HospitalA-admin.crt \
  --key   ../vfp-governance/verifier/certs/HospitalA-admin.key \
  -H "Content-Type: application/json" \
  --data "$DATA" https://issuer-hospitala.local:9443/members/register

# ---------------------------------
echo ""
echo "-------------------> "
echo "register member Bob"
python3 gen_member_keys.py  --org org://HospitalB --who Bob

DATA=$(jq 'del(.created_at)' holder_keys/Bob.register.json)
echo $DATA

curl -vk \
  --resolve issuer-hospitalb.local:9443:192.168.1.25 \
  --cacert ../vfp-governance/verifier/certs/ca.crt \
  --cert  ../vfp-governance/verifier/certs/HospitalB-admin.crt \
  --key   ../vfp-governance/verifier/certs/HospitalB-admin.key \
  -H "Content-Type: application/json" \
  --data "$DATA" https://issuer-hospitalb.local:9443/members/register


# -----------------------------------------
# check register in HospistA
curl -sk --resolve issuer-hospitala.local:9443:192.168.1.25   \
         --cacert ../vfp-governance/verifier/certs/ca.crt   \
         --cert  ../vfp-governance/verifier/certs/HospitalA-admin.crt   \
         --key   ../vfp-governance/verifier/certs/HospitalA-admin.key  \
          https://issuer-hospitala.local:9443/members | jq .

curl -sk --resolve issuer-hospitalb.local:9443:192.168.1.25   \
         --cacert ../vfp-governance/verifier/certs/ca.crt   \
         --cert  ../vfp-governance/verifier/certs/HospitalB-admin.crt   \
         --key   ../vfp-governance/verifier/certs/HospitalB-admin.key  \
          https://issuer-hospitalb.local:9443/members | jq .

echo "done"
echo " "
# -----------------------------------------
# save private keys in the simulated secure vault mounted by holder-signer
VAULT_HOLDER_KEYS_DIR="../vfp-governance/verifier/vault/holder_keys"

mkdir -p "${VAULT_HOLDER_KEYS_DIR}"

# Docker creates a missing bind-mount source as root. Repair only this
# dedicated holder-key directory when it is not writable by the current user.
if [[ ! -w "${VAULT_HOLDER_KEYS_DIR}" ]]; then
  sudo chown "$(id -u):$(id -g)" "${VAULT_HOLDER_KEYS_DIR}"
fi

chmod 700 "${VAULT_HOLDER_KEYS_DIR}"

install -v -m 600 \
  holder_keys/Audrey.privhex \
  "${VAULT_HOLDER_KEYS_DIR}/Audrey.privhex"

install -v -m 600 \
  holder_keys/Bob.privhex \
  "${VAULT_HOLDER_KEYS_DIR}/Bob.privhex"
