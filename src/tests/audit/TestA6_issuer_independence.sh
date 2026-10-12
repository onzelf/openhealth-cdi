#!/usr/bin/env bash
set -uo pipefail

# TestA6_issuer_independence.sh
#
# Hypothesis:
#   If Hospital A and Hospital B are intended to constitute their own
#   institutional authority, ECT_A and ECT_B must be cryptographically
#   attributable to distinct issuer signing authorities.
#
# Test:
#   1. mint Audrey ECT normally through Hospital A;
#   2. mint Bob ECT normally through Hospital B;
#   3. verify JWS provenance;
#   4. determine whether BOTH tokens validate under Hospital A's signing
#      certificate/public key despite different org_iss claims.
#
# Result meanings:
#   VULNERABILITY CONFIRMED  A and B ECTs both validate under the same A key.
#   ASSUMPTION REJECTED     A validates under A key while B does not.
#   INCONCLUSIVE            mint/setup/crypto verification unavailable.
#
# Usage:
#   ./TestA6_issuer_independence.sh <active-envelope-id>

ENVELOPE_ID="${1:-}"
[[ -n "${ENVELOPE_ID}" ]] || {
  echo "Usage: $0 <active-envelope-id>" >&2
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ISSUER_PORT="${ISSUER_PORT:-9443}"
ISSUER_IP="${ISSUER_IP:-127.0.0.1}"
MINT_PROOF_HTU="${MINT_PROOF_HTU:-urn:openhealth:issuer:mint}"

CA="${SRC_DIR}/vfp-governance/verifier/certs/ca.crt"
A_CRT="${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.crt"
A_KEY="${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.key"
B_CRT="${SRC_DIR}/vfp-governance/verifier/certs/HospitalB-admin.crt"
B_KEY="${SRC_DIR}/vfp-governance/verifier/certs/HospitalB-admin.key"
AUDREY_PRIVATE="${SRC_DIR}/../secrets/holder_keys/Audrey.privhex"
BOB_PRIVATE="${SRC_DIR}/../secrets/holder_keys/Bob.privhex"
GEN_MEMBER_KEYS="${SRC_DIR}/tools/gen_member_keys.py"
MAKE_DPOP="${SRC_DIR}/tools/make_dpop_jwt_eddsa.py"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

inconclusive() {
  printf '\n? INCONCLUSIVE: %s\n' "$*" >&2
  exit 2
}

for cmd in curl jq python3; do
  command -v "${cmd}" >/dev/null 2>&1 || inconclusive "missing command ${cmd}"
done
for f in "${CA}" "${A_CRT}" "${A_KEY}" "${B_CRT}" "${B_KEY}" \
         "${AUDREY_PRIVATE}" "${BOB_PRIVATE}" "${GEN_MEMBER_KEYS}" "${MAKE_DPOP}"; do
  [[ -s "${f}" ]] || inconclusive "missing file ${f}"
done

python3 - <<'PY' >/dev/null 2>&1 || {
from cryptography import x509
from cryptography.hazmat.primitives.asymmetric import ec, rsa
PY
  inconclusive "Python cryptography package is unavailable"
}

mint() {
  local host="$1" cert="$2" key="$3" sub="$4" holder_private="$5" outfile="$6"
  local identity pub_b64 priv_hex nonce jti holder_dpop body

  identity="$(
    python3 "${GEN_MEMBER_KEYS}" \
      --derive \
      --private-key "${holder_private}" \
      --format json
  )" || return 70

  pub_b64="$(jq -er '.pub_b64' <<<"${identity}")" || return 70
  priv_hex="$(tr -d '\r\n' <"${holder_private}")"

  nonce="mint-nonce-A6-${sub}-$(python3 -c 'import secrets; print(secrets.token_urlsafe(12))')"
  jti="mint-jti-A6-${sub}-$(python3 -c 'import secrets; print(secrets.token_urlsafe(12))')"

  holder_dpop="$(
    python3 "${MAKE_DPOP}" \
      "${priv_hex}" \
      "${pub_b64}" \
      "${nonce}" \
      "${jti}" \
      POST \
      "${MINT_PROOF_HTU}" \
      "${ENVELOPE_ID}"
  )" || return 70

  body="$(
    jq -nc \
      --arg s "${sub}" \
      --arg e "${ENVELOPE_ID}" \
      --arg dpop "${holder_dpop}" \
      '{sub:$s,envelope_id:$e,holder_dpop:$dpop}'
  )" || return 70

  curl -sS \
    --resolve "${host}:${ISSUER_PORT}:${ISSUER_IP}" \
    --cacert "${CA}" \
    --cert "${cert}" \
    --key "${key}" \
    -o "${outfile}" \
    -w '%{http_code}' \
    -H 'content-type: application/json' \
    -d "${body}" \
    "https://${host}:${ISSUER_PORT}/mint"
}

echo "== Mint normal Hospital A / Audrey ECT =="

A_STATUS="$(mint issuer-hospitala.local "${A_CRT}" "${A_KEY}" Audrey "${AUDREY_PRIVATE}" "${TMP}/a.json")"
A_RC=$?
[[ ${A_RC} -eq 0 ]] || {
  [[ ${A_RC} -eq 70 ]] && {
    printf '\n! HARNESS ERROR: could not construct Audrey holder mint proof\n' >&2
    exit 70
  }
  inconclusive "Hospital A mint request failed"
}
[[ "${A_STATUS}" == "200" ]] || {
  cat "${TMP}/a.json" >&2 || true
  inconclusive "Hospital A mint returned HTTP ${A_STATUS}"
}

A_ECT="$(jq -r '.ect // empty' "${TMP}/a.json")"
[[ -n "${A_ECT}" ]] || inconclusive "Hospital A mint returned no ECT"

echo "✓ Hospital A ECT minted"

echo
echo "== Mint normal Hospital B / Bob ECT =="

B_STATUS="$(mint issuer-hospitalb.local "${B_CRT}" "${B_KEY}" Bob "${BOB_PRIVATE}" "${TMP}/b.json")"
B_RC=$?
[[ ${B_RC} -eq 0 ]] || {
  [[ ${B_RC} -eq 70 ]] && {
    printf '\n! HARNESS ERROR: could not construct Bob holder mint proof\n' >&2
    exit 70
  }
  inconclusive "Hospital B mint request failed"
}
[[ "${B_STATUS}" == "200" ]] || {
  cat "${TMP}/b.json" >&2 || true
  inconclusive "Hospital B mint returned HTTP ${B_STATUS}"
}

B_ECT="$(jq -r '.ect // empty' "${TMP}/b.json")"
[[ -n "${B_ECT}" ]] || inconclusive "Hospital B mint returned no ECT"

echo "✓ Hospital B ECT minted"

python3 - \
  "${A_CRT}" \
  "${A_ECT}" \
  "${B_ECT}" \
  "${ENVELOPE_ID}" \
  >"${TMP}/analysis.json" <<'PY'
import base64
import hashlib
import json
import sys

from cryptography import x509
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature

cert_path, ect_a, ect_b, envelope_id = sys.argv[1:5]

def b64d(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))

def parse(token):
    p = token.split(".")
    if len(p) != 3:
        raise ValueError("not compact JWS")
    header = json.loads(b64d(p[0]))
    payload = json.loads(b64d(p[1]))
    sig = b64d(p[2])
    signed = (p[0] + "." + p[1]).encode("ascii")
    return header, payload, sig, signed

cert = x509.load_pem_x509_certificate(open(cert_path, "rb").read())
pub = cert.public_key()

def verifies(token):
    h, p, sig, signed = parse(token)
    alg = h.get("alg")
    try:
        if alg == "ES256":
            if not isinstance(pub, ec.EllipticCurvePublicKey) or len(sig) != 64:
                return False
            r = int.from_bytes(sig[:32], "big")
            s = int.from_bytes(sig[32:], "big")
            pub.verify(encode_dss_signature(r, s), signed, ec.ECDSA(hashes.SHA256()))
        elif alg == "ES384":
            if not isinstance(pub, ec.EllipticCurvePublicKey) or len(sig) != 96:
                return False
            r = int.from_bytes(sig[:48], "big")
            s = int.from_bytes(sig[48:], "big")
            pub.verify(encode_dss_signature(r, s), signed, ec.ECDSA(hashes.SHA384()))
        elif alg == "RS256":
            if not isinstance(pub, rsa.RSAPublicKey):
                return False
            pub.verify(sig, signed, padding.PKCS1v15(), hashes.SHA256())
        else:
            raise RuntimeError("unsupported_alg:" + str(alg))
        return True
    except Exception:
        return False

ha, pa, _, _ = parse(ect_a)
hb, pb, _, _ = parse(ect_b)

spki = pub.public_bytes(
    encoding=__import__("cryptography.hazmat.primitives.serialization",
                        fromlist=["Encoding"]).Encoding.DER,
    format=__import__("cryptography.hazmat.primitives.serialization",
                      fromlist=["PublicFormat"]).PublicFormat.SubjectPublicKeyInfo,
)
fingerprint = hashlib.sha256(spki).hexdigest()

result = {
    "hospital_a": {
        "header": ha,
        "sub": pa.get("sub"),
        "org_iss": pa.get("org_iss"),
        "envelope_id": pa.get("envelope_id"),
        "verifies_with_hospital_a_cert": verifies(ect_a),
    },
    "hospital_b": {
        "header": hb,
        "sub": pb.get("sub"),
        "org_iss": pb.get("org_iss"),
        "envelope_id": pb.get("envelope_id"),
        "verifies_with_hospital_a_cert": verifies(ect_b),
    },
    "hospital_a_public_key_sha256": fingerprint,
}
print(json.dumps(result, indent=2, sort_keys=True))
PY

RC=$?
[[ ${RC} -eq 0 ]] || inconclusive "JWS provenance analysis failed"

cat "${TMP}/analysis.json"

A_SUB="$(jq -r '.hospital_a.sub // empty' "${TMP}/analysis.json")"
A_ORG="$(jq -r '.hospital_a.org_iss // empty' "${TMP}/analysis.json")"
A_ENV="$(jq -r '.hospital_a.envelope_id // empty' "${TMP}/analysis.json")"
A_VERIFY="$(jq -r '.hospital_a.verifies_with_hospital_a_cert' "${TMP}/analysis.json")"

B_SUB="$(jq -r '.hospital_b.sub // empty' "${TMP}/analysis.json")"
B_ORG="$(jq -r '.hospital_b.org_iss // empty' "${TMP}/analysis.json")"
B_ENV="$(jq -r '.hospital_b.envelope_id // empty' "${TMP}/analysis.json")"
B_VERIFY="$(jq -r '.hospital_b.verifies_with_hospital_a_cert' "${TMP}/analysis.json")"

[[ "${A_SUB}" == "Audrey" && "${A_ORG}" == "org://HospitalA" && "${A_ENV}" == "${ENVELOPE_ID}" ]] || \
  inconclusive "Hospital A token claims are not the expected control"

[[ "${B_SUB}" == "Bob" && "${B_ORG}" == "org://HospitalB" && "${B_ENV}" == "${ENVELOPE_ID}" ]] || \
  inconclusive "Hospital B token claims are not the expected control"

[[ "${A_VERIFY}" == "true" ]] || \
  inconclusive "Hospital A ECT does not validate under Hospital A certificate; signing-key mapping differs from expected deployment"

if [[ "${B_VERIFY}" == "true" ]]; then
  echo
  echo "✗ VULNERABILITY CONFIRMED: Hospital A and Hospital B ECTs are cryptographically signed by the same Hospital A authority key"
  echo "  org_iss distinguishes them only as a signed claim, not as independent issuer provenance."
  exit 1
fi

echo
echo "✓ ASSUMPTION REJECTED: Hospital B ECT does not validate under Hospital A signing key"
exit 0
