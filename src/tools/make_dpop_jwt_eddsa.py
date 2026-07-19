#!/usr/bin/env python3
"""
make_dpop_jwt_eddsa.py
Canonical-ish DPoP proof as a compact JWS (JWT) signed with Ed25519 (EdDSA).

Usage:
  python3 make_dpop_jwt_eddsa.py <privhex> <pubb64> <nonce> <jti> <method> <htu_full_url>

Outputs:
  compact JWS string: header.payload.signature
"""

import sys, json, base64, time
from nacl import signing

def b64u(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")

def b64u_json(obj) -> str:
    return b64u(json.dumps(obj, separators=(",", ":"), sort_keys=True).encode("utf-8"))

def main():
    if len(sys.argv) != 8:
        print("Usage: python3 make_dpop_jwt_eddsa.py <privhex> <pubb64> <nonce> <jti> <htm> <htu> <envelope_id>")
        sys.exit(1)

    priv_hex = sys.argv[1]
    pub_b64  = sys.argv[2]      # base64url of raw Ed25519 public key bytes
    nonce    = sys.argv[3]
    jti      = sys.argv[4]
    method   = sys.argv[5].upper()
    htu      = sys.argv[6]      # full URL, e.g. http://127.0.0.1:9100/probe
    envelope_id = sys.argv[7]

    # DPoP JWT header with embedded JWK (OKP Ed25519)
    header = {
        "typ": "dpop+jwt",
        "alg": "EdDSA",
        "jwk": {"kty":"OKP","crv":"Ed25519","x": pub_b64},
    }

    payload = {
        "htu": htu,
        "htm": method,
        "iat": int(time.time()),
        "jti": jti,
        "nonce": nonce,
        "envelope_id": envelope_id
    }

    h_b64 = b64u_json(header)
    p_b64 = b64u_json(payload)
    signing_input = f"{h_b64}.{p_b64}".encode("ascii")

    sk = signing.SigningKey(bytes.fromhex(priv_hex))
    sig = sk.sign(signing_input).signature
    s_b64 = b64u(sig)

    print(f"{h_b64}.{p_b64}.{s_b64}")

if __name__ == "__main__":
    main()

