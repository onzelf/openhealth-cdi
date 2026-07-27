# signer.py
import os, time, base64, json, binascii, pathlib
from typing import Optional
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

from cryptography.hazmat.primitives.asymmetric import ed25519
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

HOLDER_KEYS_DIR = os.getenv("HOLDER_KEYS_DIR", "/vault/holder_keys").strip()

app = FastAPI(title="holder-signer")

def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")

def _sha256(data: bytes) -> bytes:
    d = hashes.Hash(hashes.SHA256())
    d.update(data)
    return d.finalize()

def _pub_b64_from_sk(sk: ed25519.Ed25519PrivateKey) -> str:
    pk = sk.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    return _b64url(pk)

def _load_holder_sk(sub: str) -> ed25519.Ed25519PrivateKey:
    p = pathlib.Path(HOLDER_KEYS_DIR) / f"{sub}.privhex"
    if not p.exists():
        raise HTTPException(404, f"holder_key_missing:{sub}")
    raw = binascii.unhexlify(p.read_text().strip())
    return ed25519.Ed25519PrivateKey.from_private_bytes(raw)

def _jws_eddsa(sk: ed25519.Ed25519PrivateKey, header: dict, payload: dict) -> str:
    h = _b64url(json.dumps(header, separators=(",", ":"), sort_keys=True).encode())
    p = _b64url(json.dumps(payload, separators=(",", ":"), sort_keys=True).encode())
    msg = f"{h}.{p}".encode()
    sig = sk.sign(msg)
    return f"{h}.{p}.{_b64url(sig)}"

class DPoPSignReq(BaseModel):
    sub: str
    htu: str
    htm: str = "POST"
    jti: str
    envelope_id: str
    nonce: Optional[str] = None
    iat: Optional[int] = None

@app.post("/dpop/sign")
def dpop_sign(req: DPoPSignReq):
    sk = _load_holder_sk(req.sub)
    pub_b64 = _pub_b64_from_sk(sk)

    iat = req.iat or int(time.time())
    header = {
        "typ": "dpop+jwt",
        "alg": "EdDSA",
        "jwk": {"kty": "OKP", "crv": "Ed25519", "x": pub_b64},
    }
    payload = {
        "htu": req.htu,
        "htm": req.htm,
        "iat": iat,
        "jti": req.jti,
        "envelope_id": req.envelope_id,
    }
    if req.nonce:
        payload["nonce"] = req.nonce

    dpop = _jws_eddsa(sk, header, payload)
    return {"dpop": dpop, "pub_b64": pub_b64, "iat": iat}
