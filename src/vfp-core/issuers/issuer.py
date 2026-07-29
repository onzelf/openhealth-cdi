import os
import time
from typing import Dict, Optional

import requests
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

import json
import pathlib
from threading import Lock

app = FastAPI()

ORG = os.getenv("ORG", "").strip()  # e.g., org://HospitalA
VERIFIER_URL = os.getenv("VERIFIER_URL", "https://verifier-proxy:8443").rstrip("/")

VERIFY_TLS = os.getenv("VERIFY_TLS", "0").strip()
CA_CRT = os.getenv("CA_CRT", "/run/certs/ca.crt")
ADMIN_CRT = os.getenv("ADMIN_CRT", "/run/certs/admin.crt")
ADMIN_KEY = os.getenv("ADMIN_KEY", "/run/certs/admin.key")

REGISTRY_DIR = os.getenv("REGISTRY_DIR", "/vault/registry")

_registry_lock = Lock()

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
    if VERIFY_TLS in ("0", "false", "False", ""):
        return False
    return CA_CRT

class MintReq(BaseModel):
    sub: str
    envelope_id: str
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
        reg[entry["sub"]] = entry
        _save_registry(ORG, reg)

    return {"status": "ok", "sub": entry["sub"]}

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

    # The issuer, not the caller, assigns the authorization profile.
    entitlement_org = str(MEMBER_ENTITLEMENTS.get("org", "")).strip()
    if entitlement_org != ORG:
        raise HTTPException(
            500,
            f"entitlement_org_mismatch:{entitlement_org}",
        )

    profile = (MEMBER_ENTITLEMENTS.get("members") or {}).get(subject)
    if not profile:
        raise HTTPException(403, f"no_entitlement_for_sub:{subject}")

    cap_profile = CAP_PROFILE_BY_ORG.get(ORG, {}).get(profile)
    if not cap_profile:
        raise HTTPException(
            500,
            f"entitlement_profile_not_configured:{profile}",
        )

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
                "cap_profiles": [cap_profile],
                "envelope_id": req.envelope_id,
                "nbf": nbf,
                "exp": exp,
                # Optional: if verifier can embed cnf.jkt, pass it through:
                # "holder_jkt": m["jkt"],
                # "sub": m["sub"],
                # "issuer": ORG,
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
 