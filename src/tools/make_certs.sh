#!/usr/bin/env bash
set -euo pipefail

# Where to write certs (relative to repo root)
CERT_DIR="$(cd "$(dirname "$0")/.."; pwd)/vfp-governance/verifier/certs"
mkdir -p "$CERT_DIR"
cd "$CERT_DIR"

# Guard against Docker creating directories for missing bind-mounted files
for f in \
  ca.key ca.crt \
  verifier.key verifier.crt \
  hub.key hub.crt \
  HospitalA-admin.key HospitalA-admin.crt \
  HospitalB-admin.key HospitalB-admin.crt \
  issuer-proxy.key issuer-proxy.crt
do
  if [[ -d "$f" ]]; then
    echo "ERROR: expected certificate file is a directory: $CERT_DIR/$f" >&2
    echo "Remove the bogus bind-mount directory before retrying." >&2
    exit 1
  fi
done

echo "[make_certs] cleaning TLS material in $CERT_DIR"
rm -v -f \
  ca.key ca.crt ca.srl \
  verifier.key verifier.crt verifier.csr \
  hub.key hub.crt hub.csr \
  HospitalA-admin.key HospitalA-admin.crt HospitalA-admin.csr HospitalA-admin.p12 \
  HospitalB-admin.key HospitalB-admin.crt HospitalB-admin.csr HospitalB-admin.p12 \
  issuer-proxy.key issuer-proxy.crt issuer-proxy.csr \
  2>/dev/null || true

# --------------------------------------------
# Parameters
# --------------------------------------------
PARAM=${1:-false}
PARAM=${PARAM,,}
                  
DAYS_CA=3650
DAYS_LEAF=825

# Subjects (CNs)
CN_CA="fcac-demo-ca"
CN_VERIFIER="verifier.local"
CN_HUB="hub"
CN_ORG_A="org_HospitalA_admin"
CN_ORG_B="org_HospitalB_admin"
CN_ISSUER_PROXY="issuer-proxy"

echo "(1) [make_certs] generating CA: $CN_CA"
openssl genrsa -out ca.key 4096
openssl req -x509 -new -key ca.key -subj "/CN=${CN_CA}" -sha256 -days "$DAYS_CA" -out ca.crt

#echo  "[make_certs] generating verifier server cert: $CN_VERIFIER"
echo "(2) [make_certs] generating verifier server cert (SAN): $CN_VERIFIER"
openssl genrsa -out verifier.key 2048
openssl req -new -key verifier.key -subj "/CN=${CN_VERIFIER}" -out verifier.csr

# Add SAN + serverAuth via an openssl v3 extensions file
EXT_TMP="$(mktemp)"
cat > "${EXT_TMP}" <<EOF
[ v3_server ]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = ${CN_VERIFIER}      # verifier.local
DNS.2 = verifier-proxy
DNS.3 = localhost
IP.1  = 127.0.0.1
EOF

openssl x509 -req -in verifier.csr \
  -CA ca.crt -CAkey ca.key -CAcreateserial \
  -sha256 -days "$DAYS_LEAF" \
  -out verifier.crt \
  -extfile "${EXT_TMP}" -extensions v3_server

rm -f verifier.csr "${EXT_TMP}"

# Hard regression check: ensure SAN is present
openssl x509 -in verifier.crt -noout -ext subjectAltName | grep -q "DNS:${CN_VERIFIER}" \
  || { echo "ERROR: verifier.crt missing SAN DNS:${CN_VERIFIER}"; exit 1; }

echo "(3) [make_certs] generating hub mTLS client cert: $CN_HUB"
openssl genrsa -out hub.key 2048
openssl req -new -key hub.key -subj "/CN=${CN_HUB}" -out hub.csr
openssl x509 -req -in hub.csr -CA ca.crt -CAkey ca.key -CAcreateserial -sha256 -days "$DAYS_LEAF" -out hub.crt
rm -f hub.csr

echo "(4) [make_certs] generating HospitalA admin client cert: $CN_ORG_A"
openssl genrsa -out HospitalA-admin.key 2048
openssl req -new -key HospitalA-admin.key -subj "/CN=${CN_ORG_A}" -out HospitalA-admin.csr
openssl x509 -req -in HospitalA-admin.csr -CA ca.crt -CAkey ca.key -CAcreateserial -sha256 -days "$DAYS_LEAF" -out HospitalA-admin.crt
rm -f HospitalA-admin.csr

echo "(5) [make_certs] generating HospitalB admin client cert: $CN_ORG_B"
openssl genrsa -out HospitalB-admin.key 2048
openssl req -new -key HospitalB-admin.key -subj "/CN=${CN_ORG_B}" -out HospitalB-admin.csr
openssl x509 -req -in HospitalB-admin.csr -CA ca.crt -CAkey ca.key -CAcreateserial -sha256 -days "$DAYS_LEAF" -out HospitalB-admin.crt
rm -f HospitalB-admin.csr

# -------------------------------------------------------------------------------------------
# --- issuer-proxy (nginx) server cert (SAN: issuer-hospitala.local, issuer-hospitalb.local) 
# -------------------------------------------------------------------------------------------
echo "(6) [make_certs] generating Issuer proxy client cert: $CN_ISSUER_PROXY"
ISSUER_PROXY_KEY="issuer-proxy.key"
ISSUER_PROXY_CRT="issuer-proxy.crt"
ISSUER_PROXY_CSR="$(mktemp)"

# regenerate (or guard with: if [ ! -f ... ]; then ... fi)
openssl genrsa -out "${ISSUER_PROXY_KEY}" 2048

openssl req -new \
  -key "${ISSUER_PROXY_KEY}" \
  -out "${ISSUER_PROXY_CSR}" \
  -subj "/CN=issuer-proxy" 

openssl x509 -req \
  -in "${ISSUER_PROXY_CSR}" \
  -CA "ca.crt" \
  -CAkey "ca.key" \
  -CAcreateserial \
  -out "${ISSUER_PROXY_CRT}" \
  -days 365 \
  -sha256  \
  -extfile <(printf "subjectAltName=DNS:issuer-hospitala.local,DNS:issuer-hospitalb.local")

rm -f "${ISSUER_PROXY_CSR}"

echo "[OK] issuer-proxy cert: ${ISSUER_PROXY_CRT}"
openssl x509 -in issuer-proxy.crt -noout -ext subjectAltName
echo " "

# --------------------------------------------------------------------

# ---- Android-friendly PKCS#12 for admins (password = <password>) ----
if [ "$PARAM" = "true" ]; then
    P12_PASS="fcac_pass" 

  # Use the exact PBE/MAC combo that worked for you.
  echo "[make_certs for ANDROID] exporting admin PKCS#12 bundles (password = ${P12_PASS})"
  openssl pkcs12 -export \
    -inkey HospitalA-admin.key -in HospitalA-admin.crt \
    -certfile ca.crt  \
    -name "HospitalA Admin" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -out HospitalA-admin.p12 \
    -passout pass:${P12_PASS}

  openssl pkcs12 -export \
    -inkey HospitalB-admin.key -in HospitalB-admin.crt \
    -certfile ca.crt \
    -name "HospitalB Admin" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -out HospitalB-admin.p12 \
    -passout pass:${P12_PASS}

  # Quick sanity (won't print secrets; just integrity)
  echo " "
  echo "[make_certs] verifying PKCS#12 integrity"
  openssl pkcs12 -info -in HospitalA-admin.p12 -noout -passin pass:${P12_PASS} >/dev/null
  openssl pkcs12 -info -in HospitalB-admin.p12 -noout -passin pass:${P12_PASS} >/dev/null
fi

echo "[make_certs] done."
ls ca.* verifier.* hub.* HospitalA-admin.* HospitalB-admin.* issuer-proxy.*
