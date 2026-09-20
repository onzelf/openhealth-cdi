import os
import time
import base64
import hashlib
import hmac
from typing import Dict, Optional

import requests
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

import json
import pathlib
from threading import Lock

app = FastAPI()

ORG = os.getenv("ORG", "").strip()  # e.g., org://HospitalA
VERIFIER_URL = os.getenv("VERIFIER_URL", "https://verifier-proxy:8443").rstrip("/")

VERIFY_TLS = os.getenv("VERIFY_TLS", "1").strip().lower()
CA_CRT = os.getenv("CA_CRT", "/run/certs/ca.crt")
ADMIN_CRT = os.getenv("ADMIN_CRT", "/run/certs/admin.crt")
ADMIN_KEY = os.getenv("ADMIN_KEY", "/run/certs/admin.key")

REGISTRY_DIR = os.getenv("REGISTRY_DIR", "/vault/registry")

_registry_lock = Lock()
_mint_replay_lock = Lock()

MINT_PROOF_HTU = os.getenv(
    "MINT_PROOF_HTU",
    "urn:openhealth:issuer:mint",
).strip()
MINT_PROOF_MAX_AGE_SECONDS = int(
    os.getenv("MINT_PROOF_MAX_AGE_SECONDS", "120")
)
MINT_PROOF_CLOCK_SKEW_SECONDS = int(
    os.getenv("MINT_PROOF_CLOCK_SKEW_SECONDS", "30")
)

def _org_slug(org: str) -> str:
    return org.replace("://", "__").replace("/", "_").replace(":", "_")

def _reg_path(org: str) -> pathlib.Path:
    pathlib.Path(REGISTRY_DIR).mkdir(parents=True, exist_ok=True)
    return pathlib.Path(REGISTRY_DIR) / f"{_org_slug(org)}.members.json"

def _load_registry(org: str) -> Dict[str, dict]:
    p = _reg_path(org)
    if not p.exists():
        return {}
    return json.loads(p.read_text())

def _save_registry(org: str, data: Dict[str, dict]) -> None:
    p = _reg_path(org)
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True))
    os.replace(tmp, p)  # atomic


def _b64url_decode(value: str) -> bytes:
    encoded = value.encode("ascii")
    encoded += b"=" * ((4 - len(encoded) % 4) % 4)
    return base64.urlsafe_b64decode(encoded)


def _jwk_thumbprint(jwk: Dict[str, str]) -> str:
    canonical = json.dumps(
        {
            "crv": jwk["crv"],
            "kty": jwk["kty"],
            "x": jwk["x"],
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    digest = hashlib.sha256(canonical).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")


def _mint_replay_path(org: str) -> pathlib.Path:
    pathlib.Path(REGISTRY_DIR).mkdir(parents=True, exist_ok=True)
    return pathlib.Path(REGISTRY_DIR) / f"{_org_slug(org)}.mint-jti.json"


def _consume_mint_jti(org: str, jti: str, now: int) -> None:
    path = _mint_replay_path(org)
    with _mint_replay_lock:
        if path.exists():
            try:
                seen = json.loads(path.read_text())
            except Exception:
                seen = {}
        else:
            seen = {}

        seen = {
            key: int(expiry)
            for key, expiry in seen.items()
            if int(expiry) > now
        }
        if jti in seen:
            raise HTTPException(409, "mint_proof_replayed")

        seen[jti] = (
            now
            + MINT_PROOF_MAX_AGE_SECONDS
            + MINT_PROOF_CLOCK_SKEW_SECONDS
        )
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(seen, indent=2, sort_keys=True))
        os.replace(tmp, path)


def _verify_holder_mint_proof(
    compact_jws: str,
    member: Dict[str, str],
    envelope_id: str,
) -> None:
    try:
        encoded_header, encoded_claims, encoded_signature = compact_jws.split(".")
        header = json.loads(_b64url_decode(encoded_header))
        claims = json.loads(_b64url_decode(encoded_claims))
        signature = _b64url_decode(encoded_signature)
    except Exception as exc:
        raise HTTPException(401, "invalid_holder_mint_proof") from exc

    if not isinstance(header, dict) or not isinstance(claims, dict):
        raise HTTPException(401, "invalid_holder_mint_proof")

    jwk = header.get("jwk") or {}
    if (
        header.get("typ") != "dpop+jwt"
        or header.get("alg") != "EdDSA"
        or not isinstance(jwk, dict)
        or jwk.get("kty") != "OKP"
        or jwk.get("crv") != "Ed25519"
        or not jwk.get("x")
    ):
        raise HTTPException(401, "invalid_holder_mint_proof_header")

    try:
        proof_jkt = _jwk_thumbprint(jwk)
    except Exception as exc:
        raise HTTPException(401, "invalid_holder_mint_proof_jwk") from exc

    if not hmac.compare_digest(str(member.get("jkt") or ""), proof_jkt):
        raise HTTPException(401, "holder_mint_key_mismatch")
    if not hmac.compare_digest(
        str(member.get("pub_b64") or ""),
        str(jwk["x"]),
    ):
        raise HTTPException(401, "holder_mint_public_key_mismatch")

    try:
        public_key = Ed25519PublicKey.from_public_bytes(
            _b64url_decode(str(jwk["x"]))
        )
        public_key.verify(
            signature,
            f"{encoded_header}.{encoded_claims}".encode("ascii"),
        )
    except (InvalidSignature, ValueError, TypeError) as exc:
        raise HTTPException(401, "invalid_holder_mint_signature") from exc

    if claims.get("htu") != MINT_PROOF_HTU:
        raise HTTPException(401, "holder_mint_htu_mismatch")
    if claims.get("htm") != "POST":
        raise HTTPException(401, "holder_mint_htm_mismatch")
    if claims.get("envelope_id") != envelope_id:
        raise HTTPException(401, "holder_mint_envelope_mismatch")

    jti = str(claims.get("jti") or "").strip()
    if not jti:
        raise HTTPException(401, "holder_mint_jti_missing")
    if not str(claims.get("nonce") or "").strip():
        raise HTTPException(401, "holder_mint_nonce_missing")

    try:
        iat = int(claims["iat"])
    except (KeyError, TypeError, ValueError) as exc:
        raise HTTPException(401, "holder_mint_iat_invalid") from exc

    now = int(time.time())
    if iat > now + MINT_PROOF_CLOCK_SKEW_SECONDS:
        raise HTTPException(401, "holder_mint_proof_from_future")
    if now - iat > MINT_PROOF_MAX_AGE_SECONDS:
        raise HTTPException(401, "holder_mint_proof_expired")

    _consume_mint_jti(ORG, jti, now)


# Organization-scoped issuer profile -> policy capset mapping.
CAP_PROFILE_BY_ORG = json.load(
    open(os.getenv("CAP_PROFILE_PATH", "config/cap_profiles.json"))
)

# Issuer-owned member entitlement assignment. The caller cannot select it.
MEMBER_ENTITLEMENTS_PATH = os.getenv(
    "MEMBER_ENTITLEMENTS_PATH",
    "/app/config/member_entitlements.json",
)
MEMBER_ENTITLEMENTS = json.load(open(MEMBER_ENTITLEMENTS_PATH))

def _verify_arg():
    if VERIFY_TLS not in ("1", "true", "yes", "on"):
        raise RuntimeError("issuer_verifier_tls_verification_disabled")
    if not CA_CRT or not pathlib.Path(CA_CRT).is_file():
        raise RuntimeError(f"issuer_verifier_ca_unavailable:{CA_CRT}")
    return CA_CRT

class MintReq(BaseModel):
    sub: str
    envelope_id: str
    holder_dpop: str
    nbf: Optional[str] = None
    exp: Optional[str] = None

    class Config:
        extra = "forbid"

class MemberRegReq(BaseModel):
    org_id: str
    member_id: str
    sub: str
    pub_b64: str
    jkt: str

@app.post("/members/register")
def register_member(req: MemberRegReq):
    if not ORG:
        raise HTTPException(500, "issuer_not_configured:missing_ORG")

    if req.org_id.strip() != ORG:
        raise HTTPException(403, f"org_mismatch:{req.org_id}")

    entry = {
        "org_id": ORG,
        "member_id": req.member_id.strip(),
        "sub": req.sub.strip(),
        "pub_b64": req.pub_b64.strip(),
        "jkt": req.jkt.strip(),
        "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }

    if not entry["member_id"] or not entry["sub"] or not entry["pub_b64"] or not entry["jkt"]:
        raise HTTPException(400, "invalid_member_record")

    # Registry is keyed by sub (issuer-namespace identity)
    with _registry_lock:
        reg = _load_registry(ORG)
        if entry["sub"] in reg:
            raise HTTPException(
                409,
                f"sub_already_registered:{entry['sub']}",
            )
        reg[entry["sub"]] = entry
        _save_registry(ORG, reg)

    return {"status": "ok", "sub": entry["sub"]}

@app.post("/members/rotate")
def rotate_member(req: MemberRegReq):
    """Replace holder public-key binding under issuer-admin authority."""
    if not ORG:
        raise HTTPException(500, "issuer_not_configured:missing_ORG")

    if req.org_id.strip() != ORG:
        raise HTTPException(403, f"org_mismatch:{req.org_id}")

    subject = req.sub.strip()
    member_id = req.member_id.strip()
    pub_b64 = req.pub_b64.strip()
    jkt = req.jkt.strip()
    if not subject or not member_id or not pub_b64 or not jkt:
        raise HTTPException(400, "invalid_member_record")

    with _registry_lock:
        reg = _load_registry(ORG)
        current = reg.get(subject)
        if current is None:
            raise HTTPException(404, f"unknown_sub:{subject}")
        if str(current.get("member_id") or "") != member_id:
            raise HTTPException(409, f"member_id_mismatch:{subject}")

        reg[subject] = {
            **current,
            "pub_b64": pub_b64,
            "jkt": jkt,
            "updated_at": time.strftime(
                "%Y-%m-%dT%H:%M:%SZ",
                time.gmtime(),
            ),
        }
        _save_registry(ORG, reg)

    return {"status": "rotated", "sub": subject, "jkt": jkt}

@app.get("/members")  # Debugging endpoint
def list_members():
    if not ORG:
        raise HTTPException(500, "issuer_not_configured:missing_ORG")
    reg = _load_registry(ORG)
    return {"org": ORG, "count": len(reg), "members": list(reg.values())}

@app.get("/rights")
def rights():
    return {"org": ORG, "profiles": sorted(CAP_PROFILE_BY_ORG.get(ORG, {}).keys())}

@app.post("/mint")
def mint(req: MintReq):
    if not ORG:
        raise HTTPException(500, "issuer_not_configured:missing_ORG")

    subject = req.sub.strip()

    # Membership authenticates the holder.
    db = _load_registry(ORG)
    m = db.get(subject)
    if not m:
        raise HTTPException(404, f"unknown_sub:{subject}")

    _verify_holder_mint_proof(
        req.holder_dpop,
        m,
        req.envelope_id,
    )

    # The issuer, not the caller, assigns the authorization profiles.
    entitlement_org = str(MEMBER_ENTITLEMENTS.get("org", "")).strip()
    if entitlement_org != ORG:
        raise HTTPException(
            500,
            f"entitlement_org_mismatch:{entitlement_org}",
        )

    profiles = (MEMBER_ENTITLEMENTS.get("members") or {}).get(subject)
    if not profiles:
        raise HTTPException(403, f"no_entitlement_for_sub:{subject}")

    if isinstance(profiles, str):
        profiles = [profiles]
    if not isinstance(profiles, list) or any(
        not isinstance(profile, str) or not profile.strip()
        for profile in profiles
    ):
        raise HTTPException(
            500,
            f"invalid_entitlement_assignment:{subject}",
        )

    cap_profiles = []
    for profile in [profile.strip() for profile in profiles]:
        cap_profile = CAP_PROFILE_BY_ORG.get(ORG, {}).get(profile)
        if not cap_profile:
            raise HTTPException(
                500,
                f"entitlement_profile_not_configured:{profile}",
            )
        if cap_profile not in cap_profiles:
            cap_profiles.append(cap_profile)

    # actor_type is issuer-attested metadata, not an authorization selector.
    actor_type = str(
        (MEMBER_ENTITLEMENTS.get("actor_types") or {}).get(subject, "human")
    ).strip()
    if actor_type not in {"human", "agent"}:
        raise HTTPException(
            500,
            f"invalid_actor_type_assignment:{subject}",
        )

    # Sponsorship is issuer-owned governance state. The caller cannot select it.
    sponsors = (MEMBER_ENTITLEMENTS.get("sponsors") or {}).get(subject, [])
    if not isinstance(sponsors, list) or any(
        not isinstance(sponsor, str) or not sponsor.strip()
        for sponsor in sponsors
    ):
        raise HTTPException(
            500,
            f"invalid_sponsor_assignment:{subject}",
        )
    sponsors = [sponsor.strip() for sponsor in sponsors]

    holder_pub_b64 = m["pub_b64"]

    # Default validity window (1h) if not provided
    now = int(time.time())
    nbf = req.nbf or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - 60))
    exp = req.exp or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now + 3600))

    try:
        r = requests.post(
            f"{VERIFIER_URL}/mint_ect",
            json={
                "holder_pub_b64": holder_pub_b64,
                "cap_profiles": cap_profiles,
                "envelope_id": req.envelope_id,
                "sub": m["sub"],
                "actor_type": actor_type,
                "sponsors": sponsors,
                "nbf": nbf,
                "exp": exp,
            },
            timeout=15,
            verify=_verify_arg(),
            cert=(ADMIN_CRT, ADMIN_KEY),
        )
        if r.status_code != 200:
            raise HTTPException(r.status_code, r.text)

        out = r.json()
        ect = out.get("ect_jws")
        if not ect:
            raise HTTPException(502, f"mint_failed:no_ect_jws:{out}")

        if ect.count(".") < 2:
            raise HTTPException(502, f"mint_failed:not_compact_jws:{out}")

        return {"ect": ect}

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(502, f"verifier_error:{e}")
 