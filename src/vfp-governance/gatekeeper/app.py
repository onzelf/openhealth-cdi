#!/usr/bin/env python3
import base64, hashlib, json, os, re, secrets, threading, time, uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

import jwt  # pyjwt
import redis.asyncio as redis
from fastapi import FastAPI, Header, HTTPException, Request, APIRouter
from fastapi.responses import HTMLResponse, JSONResponse
from pydantic import BaseModel, Field
from contextvars import ContextVar

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec, ed25519, rsa

from nacl import signing

import benchmark as benchmark_store
from benchmark import BENCH, BENCH_OUT, _ms, _ns, _bench_flush, _bench_reset
import logging

log = logging.getLogger("verifier")
_bench_current = ContextVar("bench_current", default=None)
_verified_ect_identity = ContextVar("verified_ect_identity", default=None)

def _bench_begin_request() -> None:
    if BENCH:
        _bench_current.set(None)

def _bench_add(sample: dict) -> None:
    benchmark_store._bench_add(sample)
    if BENCH:
        _bench_current.set(sample)

def _bench_finalize_request(values: dict) -> None:
    """Complete the current request sample after evidence emission."""
    if not BENCH:
        return

    sample = _bench_current.get()
    with benchmark_store._bench_lock:
        if sample is None:
            sample = {}
            benchmark_store._bench_buf.append(sample)
        sample.update(values)
    _bench_current.set(None)

log.warning("BENCH_BOOT v3: BENCH=%d BENCH_OUT=%s", BENCH, BENCH_OUT)
# =============================================================================
# Configuration (paths + env)
# =============================================================================

# Mounted by OpenTofu:
#   state/ contains: policy.json, binds/, envelopes/
#   certs/ contains: org signing key (for mint_ect), and decision key may be generated under state/keys
FCAC_STATE_DIR = Path(os.environ.get("FCAC_STATE_DIR", "/app/state")).resolve()
FCAC_CERTS_DIR = Path(os.environ.get("FCAC_CERTS_DIR", "/app/verifier/certs")).resolve()

STATE_DIR   = FCAC_STATE_DIR
ENVS_DIR    = STATE_DIR / "envelopes"
BINDS_DIR   = STATE_DIR / "binds"
POLICY_PATH = STATE_DIR / "policy.json"
EVENTS_DIR  = STATE_DIR / "events"
DECISIONS_DIR = EVENTS_DIR / "decisions"

for d in (STATE_DIR, ENVS_DIR, BINDS_DIR, EVENTS_DIR, DECISIONS_DIR):
    d.mkdir(parents=True, exist_ok=True)

REDIS_URL = os.environ.get("REDIS_URL", "redis://redis:6379/0")
REDIS_CHANNEL_ENVELOPES_CREATED = os.environ.get("FCAC_ENVELOPE_CHANNEL", "fcac:envelopes:created")
redis_client = None

# DPoP proof freshness and replay window.
# ECTs remain reusable while valid. Individual DPoP presentations do not.
DPOP_MAX_AGE_SECONDS = int(os.environ.get("DPOP_MAX_AGE_SECONDS", "60"))
DPOP_CLOCK_SKEW_SECONDS = int(os.environ.get("DPOP_CLOCK_SKEW_SECONDS", "5"))
DPOP_REPLAY_TTL_SECONDS = DPOP_MAX_AGE_SECONDS + DPOP_CLOCK_SKEW_SECONDS

# Enforce nginx mTLS headers for /verify-start by default (matches your previous behavior)
REQUIRE_MTLS_HEADERS = os.environ.get("REQUIRE_MTLS_HEADERS", "true").lower() in ("1", "true", "yes")

# Issuer constants (keep consistent with your test harness)
ISS = os.environ.get("ISS", "http://127.0.0.1:9100")
AUD_FALLBACK = os.environ.get("AUD", "svc:fl-gateway:eu")
ORG_KEY_KID = os.environ.get("ORG_KEY_KID", "HospitalA-key")
ORG_KEY_FILE = os.environ.get("ORG_KEY_FILE", str(FCAC_CERTS_DIR / "HospitalA-admin.key"))  # PEM EC/RSA

EVIDENCE_PRIVATE_KEY_FILE = Path(os.environ.get(
    "EVIDENCE_PRIVATE_KEY_FILE",
    str(FCAC_CERTS_DIR / "fcac-evidence.key"),
)).resolve()
EVIDENCE_PUBLIC_KEY_FILE = Path(os.environ.get(
    "EVIDENCE_PUBLIC_KEY_FILE",
    str(FCAC_CERTS_DIR / "fcac-evidence.pub"),
)).resolve()
EVIDENCE_KEY_KID = os.environ.get("EVIDENCE_KEY_KID", "fcac-evidence-key-1")

# Optional allowlist (comma-separated sha256_b64u policy hashes from compute_policy_hash)
POLICY_ALLOWLIST = {x.strip() for x in os.environ.get("ALLOWED_POLICY_HASHES", "").split(",") if x.strip()}

# KYO
KYO_SESSION_TTL = int(os.environ.get("KYO_SESSION_TTL", "600"))  # seconds
ENVELOPE_TTL = int(os.environ.get("ENVELOPE_TTL", "1209600"))    # temporary extended values for testing purposes (2 weeks)
SESS: dict[str, dict] = {}  # session_id -> {code, exp, claimed, org, admin_cn}
_lock = threading.Lock()


# =============================================================================
# Utilities (shared)
# =============================================================================

def now_epoch() -> int:
    return int(time.time())

def iso_to_epoch(s: str) -> int:
    return int(datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(timezone.utc).timestamp())

def b64u(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).decode().rstrip("=")

def b64u_to_bytes(s: str) -> bytes:
    pad = "=" * ((4 - len(s) % 4) % 4)
    return base64.urlsafe_b64decode(s + pad)

def jcs_bytes(obj: Any) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")

def sha256_b64u(b: bytes) -> str:
    return b64u(hashlib.sha256(b).digest())

def rfc7638_thumbprint_okp_ed25519(pub_b64u: str) -> str:
    jwk = {"crv": "Ed25519", "kty": "OKP", "x": pub_b64u}
    return sha256_b64u(jcs_bytes(jwk))

def append_event(obj: dict):
    with open(EVENTS_DIR / "events.log", "a", encoding="utf-8") as f:
        f.write(json.dumps(obj) + "\n")

async def get_redis():
    global redis_client
    if redis_client is None:
        redis_client = redis.from_url(REDIS_URL, decode_responses=True)
        # ping to surface connection errors early
        await redis_client.ping()
    return redis_client

def _read_json(p: Path, default=None):
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return default

def _write_json(p: Path, obj: dict):
    p.write_text(json.dumps(obj, indent=2), encoding="utf-8")

def _write_json_atomic(p: Path, obj: dict):
    tmp = p.with_name(f".{p.name}.{uuid.uuid4().hex}.tmp")
    tmp.write_text(json.dumps(obj, indent=2), encoding="utf-8")
    os.replace(tmp, p)

def bind_path(bind_id: str) -> Path:
    return BINDS_DIR / f"{bind_id}.json"

def env_path(eid: str) -> Path:
    return ENVS_DIR / f"{eid}.json"

def bind_load(bind_id: str) -> dict:
    b = _read_json(bind_path(bind_id))
    if not b:
        raise HTTPException(404, "unknown bind_id")
    return b

def bind_save(b: dict):
    _write_json(bind_path(b["bind_id"]), b)

def env_save(e: dict):
    _write_json(env_path(e["envelope_id"]), e)


# =============================================================================
# Anchored evidence signing for envelopes and admission decisions
# =============================================================================

def load_evidence_keys():
    if not EVIDENCE_PRIVATE_KEY_FILE.is_file():
        raise RuntimeError(
            f"FCaC evidence private key missing: {EVIDENCE_PRIVATE_KEY_FILE}"
        )
    if not EVIDENCE_PUBLIC_KEY_FILE.is_file():
        raise RuntimeError(
            f"FCaC evidence public key missing: {EVIDENCE_PUBLIC_KEY_FILE}"
        )

    private_key = serialization.load_pem_private_key(
        EVIDENCE_PRIVATE_KEY_FILE.read_bytes(),
        password=None,
    )
    public_key = serialization.load_pem_public_key(
        EVIDENCE_PUBLIC_KEY_FILE.read_bytes()
    )
    if not isinstance(private_key, ed25519.Ed25519PrivateKey):
        raise RuntimeError("FCaC evidence private key must be Ed25519")
    if not isinstance(public_key, ed25519.Ed25519PublicKey):
        raise RuntimeError("FCaC evidence public key must be Ed25519")

    private_public = private_key.public_key().public_bytes(
        serialization.Encoding.Raw,
        serialization.PublicFormat.Raw,
    )
    pinned_public = public_key.public_bytes(
        serialization.Encoding.Raw,
        serialization.PublicFormat.Raw,
    )
    if private_public != pinned_public:
        raise RuntimeError("FCaC evidence private/public key mismatch")
    return private_key, public_key


EVIDENCE_SK, EVIDENCE_PK = load_evidence_keys()


def sign_artifact(payload: dict) -> dict:
    unsigned = dict(payload)
    unsigned.pop("evidence", None)
    signature = EVIDENCE_SK.sign(jcs_bytes(unsigned))
    artifact = dict(unsigned)
    artifact["evidence"] = {
        "alg": "Ed25519",
        "kid": EVIDENCE_KEY_KID,
        "signature": b64u(signature),
    }
    return artifact


def verify_artifact(artifact: dict, expected_type: Optional[str] = None) -> None:
    evidence = artifact.get("evidence")
    if not isinstance(evidence, dict):
        raise ValueError("evidence_missing")
    if evidence.get("alg") != "Ed25519":
        raise ValueError("evidence_alg_invalid")
    if evidence.get("kid") != EVIDENCE_KEY_KID:
        raise ValueError("evidence_kid_invalid")
    if expected_type and artifact.get("artifact_type") != expected_type:
        raise ValueError("artifact_type_invalid")

    unsigned = dict(artifact)
    unsigned.pop("evidence", None)
    signature = b64u_to_bytes(str(evidence.get("signature") or ""))
    EVIDENCE_PK.verify(signature, jcs_bytes(unsigned))


def attest(decision: str, reason: str, version: str, phash: str, request_body: dict) -> dict:
    ts = int(time.time())
    payload = {
        "artifact_type": "fcac_attestation",
        "schema_version": "1.0",
        "ts": ts,
        "decision": decision,
        "reason": reason,
        "policy_version": version,
        "policy_hash": phash,
        "input": request_body,
    }
    return sign_artifact(payload)


# =============================================================================
# Policy loading + hashing (issuer_lite_eddsa semantics)
# =============================================================================

def load_policy() -> Dict[str, Any]:
    pol = _read_json(POLICY_PATH)
    if not pol:
        raise RuntimeError(f"policy.json not found at {POLICY_PATH}")
    for k in ("version", "constitutive", "ops", "cap_profiles", "meta"):
        if k not in pol:
            raise RuntimeError(f"policy.json missing '{k}'")
    return pol

def compute_policy_hash(policy: Dict[str, Any]) -> str:
    return sha256_b64u(jcs_bytes(policy))

def pick_caps(policy: Dict[str, Any], cap_profiles: List[str]) -> List[Dict[str, Any]]:
    ops = policy["ops"]
    profs = policy["cap_profiles"]
    op_ids: List[str] = []

    for pid in cap_profiles:
        entry = profs.get(pid)
        if not entry:
            raise HTTPException(400, f"cap_profile '{pid}' not found in policy.cap_profiles")
        for op_id in entry.get("cap", []):
            if op_id not in ops:
                raise HTTPException(400, f"op_id '{op_id}' from profile '{pid}' not found in policy.ops")
            if op_id not in op_ids:
                op_ids.append(op_id)

    caps: List[Dict[str, Any]] = []
    for op_id in op_ids:
        op = ops[op_id]
        cap = {}
        for k in ("resource", "action", "purpose", "scope", "flags"):
            if k in op and op[k] not in ({}, [], None, ""):
                cap[k] = op[k]
        caps.append(cap)

    # compile-time prohibitions (kept)
    prohibitions = set(policy.get("caveats", {}).get("prohibitions", []))
    if "no_export_raw" in prohibitions:
        caps = [c for c in caps if not (c.get("action") == "export" and c.get("flags", {}).get("datatype") == "raw")]

    # dedupe
    seen = set()
    uniq = []
    for c in caps:
        key = json.dumps(c, sort_keys=True)
        if key not in seen:
            seen.add(key)
            uniq.append(c)
    return uniq

def cap_match_result(
    cap: Dict[str, Any],
    req: Dict[str, Any],
) -> tuple[bool, Optional[str]]:
    if cap.get("resource") != req.get("resource"):
        return False, "capability_violation"
    if cap.get("action") != req.get("action"):
        return False, "capability_violation"

    if "purpose" in cap and cap["purpose"] != req.get("purpose"):
        return False, "capability_violation"

    if "scope" in cap and isinstance(cap["scope"], dict):
        if "pathology_labels" in cap["scope"]:
            granted_tissues = set(cap["scope"]["pathology_labels"])
            requested_tissues = set(req.get("requested_tissues", []))
            if not requested_tissues.issubset(granted_tissues):
                return False, "capability_scope_exceeded"

    if "flags" in cap and isinstance(cap["flags"], dict):
        for k, v in cap["flags"].items():
            if req.get(k) != v:
                return False, "capability_violation"

    return True, None


def cap_matches_request(cap: Dict[str, Any], req: Dict[str, Any]) -> bool:
    matched, _ = cap_match_result(cap, req)
    return matched


# =============================================================================
# Org signing key loading (issuer_lite_eddsa semantics)
# =============================================================================

def load_org_key_and_alg():
    pem = Path(ORG_KEY_FILE).read_bytes()
    key = serialization.load_pem_private_key(pem, password=None)
    if isinstance(key, ec.EllipticCurvePrivateKey):
        curve = key.curve.name.lower()
        alg = "ES256" if "p-256" in curve or "secp256r1" in curve else "ES384" if "384" in curve else "ES512"
    elif isinstance(key, rsa.RSAPrivateKey):
        alg = "RS256"
    else:
        raise RuntimeError("Unsupported org private key type (need EC or RSA PEM)")
    return pem, key.public_key(), alg


# =============================================================================
# Models (issuer_lite_eddsa semantics)
# =============================================================================

class MintReq(BaseModel):
    holder_pub_b64: str = Field(..., description="Ed25519 public key, base64url (from gen_member_keys.py)")
    cap_profiles: List[str] = Field(..., description="cap profile ids to grant (must exist in policy.cap_profiles)")
    envelope_id: str = Field(..., min_length=1, description="Active federation envelope bound into the ECT")
    sub: str = Field(..., min_length=1)
    actor_type: str = Field(..., min_length=1)
    sponsors: Optional[List[str]] = None
    nbf: str
    exp: str

class MintResp(BaseModel):
    ect_jws: str
    policy_hash: str
    alg: str
    kid: str

class ProbeReq(BaseModel):
    envelope_id: str = Field(..., min_length=1)
    run_id: str = Field(..., min_length=1)
    resource: str
    action: str
    purpose: Optional[str] = None
    requested_tissues: List[str]
    agg: Optional[str] = None
    pii: Optional[bool] = None
    contact: Optional[bool] = None
    derivative_representation: Optional[str] = None
    governed_value_id: Optional[str] = None
    jti: Optional[str] = None  # echoed in DPoP signed content

class ProbeResp(BaseModel):
    allow: bool
    reason: Optional[str] = None
    decision_id: Optional[str] = None


# =============================================================================
# App init
# =============================================================================

app = FastAPI(title="FCaC Gatekeeper (Envelope + Admission)")

_policy = load_policy()
_policy_hash = compute_policy_hash(_policy)
_org_priv_pem, _org_pub, _alg = load_org_key_and_alg()
_aud = _policy.get("caveats", {}).get("audience", AUD_FALLBACK)


# =============================================================================
# Envelope/KYO endpoints (ported + cleaned)
# =============================================================================

def _hdr(req: Request, name: str) -> str:
    v = req.headers.get(name)
    return v if v is not None else ""

def _minting_org(req: Request) -> str:
    if _hdr(req, "X-SSL-Client-Verify") != "SUCCESS":
        raise HTTPException(401, "client cert required")

    dn = _hdr(req, "X-SSL-Client-S-DN")
    match = re.search(
        r"CN=org_([A-Za-z0-9][A-Za-z0-9._-]*)_admin",
        dn,
    )
    if not match:
        raise HTTPException(403, "minting_org_not_resolved")
    return f"org://{match.group(1)}"

def _load_env_summary(p: Path):
    try:
        e = json.loads(p.read_text(encoding="utf-8"))
        verify_artifact(e, "fcac_envelope")
        return {
            "envelope_id": e.get("envelope_id"),
            "state": e.get("state"),
            "exp": e.get("exp") or e.get("valid_until"),
            "policy_hash": e.get("policy_hash"),
            "participants": [pp.get("org") for pp in e.get("participants", [])],
            "quorum": e.get("quorum", {}),
        }
    except Exception:
        return None

# ==============================================
# /bench/* endpoints
# ----------------------------------------------
# POST  /bench/flush
@app.post("/bench/flush")
def bench_flush():
    n = _bench_flush()
    return {"ok": True, "flushed": n, "path": BENCH_OUT}

# POST /bench/reset
@app.post("/bench/reset")
def bench_reset():
    n = _bench_reset()    
    return {"ok": True, "cleared": n}

# -----------------------------------------------
# GET /status
# ----------------------------------------------
@app.get("/status")
def status(state: str = "ACTIVE"):
    wanted = state.upper()
    out = []
    for f in sorted(ENVS_DIR.glob("*.json")):
        s = _load_env_summary(f)
        if not s:
            continue
        if wanted == "ANY" or (s.get("state") == wanted):
            out.append(s)
    return {"ok": True, "ts": now_epoch(), "envelopes": out}

# -----------------------------------------------
# GET/POST /verify-start
# ----------------------------------------------
@app.api_route("/verify-start", methods=["GET", "POST"])
async def verify_start(req: Request):
    if REQUIRE_MTLS_HEADERS and _hdr(req, "X-SSL-Client-Verify") != "SUCCESS":
        raise HTTPException(401, "client cert required")

    dn = _hdr(req, "X-SSL-Client-S-DN")
    m_cn = re.search(r"CN=([^,]+)", dn or "")
    admin_cn = m_cn.group(1) if m_cn else "unknown_admin"

    org_uri = "org://Unknown"
    m1 = re.match(r"org[_-]([A-Za-z0-9][A-Za-z0-9._-]*)_(admin|owner|member)$", admin_cn)
    m2 = re.match(r"org://([A-Za-z0-9][A-Za-z0-9._-]*)(?:/.*)?$", admin_cn)
    if m1:
        org_uri = f"org://{m1.group(1)}"
    elif m2:
        org_uri = f"org://{m2.group(1)}"

    sid = secrets.token_urlsafe(16)
    code = f"{secrets.randbelow(1_000_000):06d}"
    exp = now_epoch() + KYO_SESSION_TTL
    with _lock:
        SESS[sid] = {"code": code, "exp": exp, "claimed": False, "org": org_uri, "admin_cn": admin_cn}

    append_event({"kyo_start": {"session_id": sid, "code": code, "org": org_uri, "admin_cn": admin_cn, "ts": now_epoch()}})

    html = f"""
    <html><body style="font-family: system-ui; text-align:center; padding-top:3rem">
      <h1>Verification Code</h1>
      <div style="font-size:64px;font-weight:700;letter-spacing:4px">{code}</div>
      <p>Give this code to the admin to authorize binding.</p>
    </body></html>
    """
    return HTMLResponse(html)

# -----------------------------------------------
# /session/claim
# ----------------------------------------------
@app.get("/session/claim")
def session_claim(code: str):
    now_ts = now_epoch()
    with _lock:
        for sid, s in SESS.items():
            if s.get("code") == code and s.get("exp", 0) > now_ts:
                already = bool(s.get("claimed"))
                s["claimed"] = True
                if already:
                    append_event({"kyo_claim_duplicate": {"session_id": sid, "code": code, "org": s.get("org"), "ts": now_ts}})
                else:
                    append_event({"kyo_claim": {"session_id": sid, "org": s.get("org"), "ts": now_ts}})
                return {
                    "session_id": sid,
                    "exp": s["exp"],
                    "org": s.get("org", "org://Unknown"),
                    "admin_cn": s.get("admin_cn", "unknown_admin"),
                    "already_claimed": already,
                }
    raise HTTPException(404, "no valid session for code")

# -----------------------------------------------
# POST /abeta/bind/init
# ----------------------------------------------
def _constitutive_bind_terms():
    config = _policy.get("constitutive")
    if not isinstance(config, dict):
        raise RuntimeError("policy constitutive block invalid")

    participants = config.get("participants")
    quorum = config.get("quorum")

    if not isinstance(participants, list) or not participants:
        raise RuntimeError("policy constitutive participants invalid")

    orgs = []
    for participant in participants:
        if (
            not isinstance(participant, dict)
            or not isinstance(participant.get("org"), str)
            or not participant["org"]
        ):
            raise RuntimeError("policy constitutive participant invalid")
        orgs.append(participant["org"])

    if len(set(orgs)) != len(orgs):
        raise RuntimeError("policy constitutive participants duplicated")

    if not isinstance(quorum, dict):
        raise RuntimeError("policy constitutive quorum invalid")

    k = quorum.get("k")
    n = quorum.get("n")
    if (
        not isinstance(k, int)
        or isinstance(k, bool)
        or not isinstance(n, int)
        or isinstance(n, bool)
        or n != len(participants)
        or not 1 <= k <= n
    ):
        raise RuntimeError("policy constitutive quorum invalid")

    # Copy because bind approval enriches participant records with admin_cn.
    return (
        json.loads(json.dumps(participants)),
        {"k": k, "n": n},
    )


@app.post("/beta/bind/init")
async def bind_init(req: Request):
    try:
        caller = await req.json()
    except Exception:
        caller = {}

    if not isinstance(caller, dict):
        raise HTTPException(400, "bind_init_body_must_be_object")

    policy_owned = {"participants", "quorum", "scope", "allowed_ops"}
    attempted = sorted(policy_owned.intersection(caller))
    if attempted:
        raise HTTPException(
            400,
            "bind_terms_are_policy_owned:" + ",".join(attempted),
        )
    if caller:
        raise HTTPException(400, "unsupported_bind_init_fields")

    participants, quorum = _constitutive_bind_terms()
    bid = "b" + uuid.uuid4().hex[:12]
    ph = _policy_hash

    rec = {
        "bind_id": bid,
        "state": "PENDING",
        "participants": participants,
        "quorum": quorum,
        "approvals": [],
        "policy_hash": ph,
        "ts": now_epoch(),
    }
    bind_save(rec)
    append_event({
        "bind_init": {
            "bind_id": bid,
            "policy_hash": ph,
            "participants": [p["org"] for p in participants],
            "quorum": quorum,
        }
    })
    return {"ok": True, "bind_id": bid, "policy_hash": ph}

# -----------------------------------------------
# POST /beta/bind/approve
# ----------------------------------------------
@app.post("/beta/bind/approve")
async def bind_approve(req: Request):
    body = await req.json()
    bind_id = body.get("bind_id")
    session_id = body.get("session_id")
    if not bind_id or not session_id:
        raise HTTPException(400, "missing bind_id/session_id")

    b = bind_load(bind_id)
    if b["state"] != "PENDING":
        return JSONResponse({"bind_id": bind_id, "state": b["state"], "message": "bind already finalized"})

    s = SESS.get(session_id)
    if not s:
        raise HTTPException(401, "unknown session")
    if not s.get("claimed"):
        raise HTTPException(401, "session not claimed")
    if s.get("exp", 0) < time.time():
        raise HTTPException(401, "expired session")

    org = s.get("org", "org://Unknown")
    cn = s.get("admin_cn", "unknown_admin")

    part_orgs = [p["org"] for p in b["participants"]]
    if org not in part_orgs:
        raise HTTPException(403, f"{org} not in participants")

    if any(a["session_id"] == session_id for a in b["approvals"]):
        unique_orgs = len(set(a["org"] for a in b["approvals"]))
        required = b["quorum"]["k"]
        return JSONResponse({
            "bind_id": bind_id,
            "state": "PENDING",
            "unique_orgs_approved": unique_orgs,
            "required": required,
            "policy_hash": b["policy_hash"],
            "message": "session already approved"
        })

    b["approvals"].append({"org": org, "admin_cn": cn, "session_id": session_id, "ts": now_epoch()})

    for p in b["participants"]:
        if p["org"] == org and "admin_cn" not in p:
            p["admin_cn"] = cn

    unique_orgs = set(a["org"] for a in b["approvals"])
    approved_count = len(unique_orgs)
    required = b["quorum"]["k"]

    bind_save(b)
    append_event({"bind_approve": {"bind_id": bind_id, "org": org, "session_id": session_id,
                                  "unique_orgs_approved": approved_count, "required": required, "ts": now_epoch()}})

    if approved_count < required:
        return JSONResponse({
            "bind_id": bind_id,
            "state": "PENDING",
            "unique_orgs_approved": approved_count,
            "required": required,
            "policy_hash": b["policy_hash"],
        })

    # Quorum met: create envelope
    eid = str(uuid.uuid4())
    env = {
        "artifact_type": "fcac_envelope",
        "schema_version": "1.0",
        "bind_id": bind_id,
        "envelope_id": eid,
        "state": "ACTIVE",
        "created_at": now_epoch(),
        "activated_at": now_epoch(),
        "valid_until": now_epoch() + ENVELOPE_TTL,
        "participants": b["participants"],
        "policy_hash": b["policy_hash"],
        "quorum": b["quorum"],
        "lineage": [],
        "initiators": [{"session_id": a["session_id"], "org": a["org"]} for a in b["approvals"]],
    }
    env = sign_artifact(env)
    env_save(env)
    b["state"] = "COMPLETED"
    bind_save(b)

    append_event({"envelope_created": {"bind_id": bind_id, "envelope_id": eid, "policy_hash": b["policy_hash"],
                                      "unique_orgs": list(unique_orgs), "ts": now_epoch()}})

    # Publish to Redis for Hub
    try:
        r = await get_redis()
        envelope_event = {
            "envelope_id": eid,
            "policy_hash": env["policy_hash"],
            "valid_until": env["valid_until"],
            "participants": [p.get("org") for p in env["participants"]],
            "created_at": now_epoch(),
        }
        await r.publish(REDIS_CHANNEL_ENVELOPES_CREATED, json.dumps(envelope_event))
        print(f"[gatekeeper] Published envelope creation: {eid}", flush=True)
    except Exception as ex:
        print(f"[gatekeeper] Warning: failed to publish backend assignment: {ex}", flush=True)

    # Attestation (envelope evidence)
    att = attest(
        "PERMIT",
        "envelope_active",
        _policy.get("version", "1.00"),
        _policy_hash,
        {"envelope_id": eid, "bind_id": bind_id},
    )

    return JSONResponse({
        "state": "ACTIVE",
        "envelope_id": eid,
        "bind_id": bind_id,
        "policy_hash": b["policy_hash"],
        "exp": env["valid_until"],
        "unique_orgs_approved": approved_count,
        "attestation": att,
    })


# ================================================
# Admission endpoints 
# ================================================
# ------------------------------------------------
# GET /health
# ------------------------------------------------
@app.get("/health")
def health():
    return {
        "ok": True,
        "policy_path": str(POLICY_PATH),
        "policy_hash": _policy_hash,
        "alg": _alg,
        "iss": ISS,
        "aud": _aud,
    }

# -----------------------------------------------
# POST /mint_ect
# ----------------------------------------------
def load_active_envelope(envelope_id: str) -> Dict[str, Any]:
    envelope = _read_json(env_path(envelope_id))
    if not envelope:
        raise HTTPException(400, "unknown_envelope")
    if not isinstance(envelope.get("evidence"), dict):
        raise HTTPException(400, "envelope_signature_missing")
    try:
        verify_artifact(envelope, "fcac_envelope")
    except Exception:
        raise HTTPException(400, "envelope_signature_invalid")

    if envelope.get("state") != "ACTIVE":
        raise HTTPException(400, "envelope_not_active")

    valid_until = envelope.get("valid_until") or envelope.get("exp")
    if valid_until is None:
        raise HTTPException(400, "envelope_missing_expiry")
    if int(valid_until) <= now_epoch():
        raise HTTPException(400, "envelope_expired")

    envelope_policy_hash = str(envelope.get("policy_hash") or "")
    if not envelope_policy_hash:
        raise HTTPException(400, "envelope_missing_policy_hash")
    if envelope_policy_hash != _policy_hash:
        raise HTTPException(400, "envelope_current_policy_mismatch")

    return envelope


def _sponsorship_validation_reason(
    cap_profiles: Any,
    sponsors_claim: Any,
    org_iss: str,
    envelope: Dict[str, Any],
) -> Optional[str]:
    if not isinstance(cap_profiles, list) or any(
        not isinstance(profile, str) or not profile
        for profile in cap_profiles
    ):
        return "sponsorship_profiles_invalid"

    if sponsors_claim is None:
        sponsors = []
    elif isinstance(sponsors_claim, list):
        sponsors = sponsors_claim
    else:
        return "sponsorship_claim_invalid"

    if any(
        not isinstance(sponsor, str)
        or re.fullmatch(
            r"org://[A-Za-z0-9][A-Za-z0-9._-]*",
            sponsor,
        ) is None
        for sponsor in sponsors
    ):
        return "sponsorship_sponsor_invalid"

    if len(set(sponsors)) != len(sponsors):
        return "sponsorship_duplicate_sponsor"

    participant_orgs = {
        str(participant.get("org"))
        for participant in envelope.get("participants", [])
        if isinstance(participant, dict) and participant.get("org")
    }

    rules = _policy.get("sponsorship_rules", {})
    if not isinstance(rules, dict):
        return "sponsorship_policy_invalid"

    authority = _policy.get("sponsorship_authority", {})
    if not isinstance(authority, dict):
        return "sponsorship_policy_invalid"

    eligible_sponsors = authority.get("eligible_sponsor_organizations")
    if not isinstance(eligible_sponsors, list) or any(
        not isinstance(sponsor, str) or not sponsor
        for sponsor in eligible_sponsors
    ):
        return "sponsorship_policy_invalid"

    eligible_sponsor_set = set(eligible_sponsors)
    require_active_envelope_participation = authority.get(
        "require_active_envelope_participation"
    )
    if require_active_envelope_participation is not True:
        return "sponsorship_policy_invalid"

    for profile in cap_profiles:
        rule = rules.get(profile)

        # No rule means this profile is explicitly unsponsored.
        # Every profile carried by a multi-profile ECT must be satisfied.
        if rule is None:
            if sponsors:
                return "sponsorship_not_permitted"
            continue

        if not isinstance(rule, dict):
            return "sponsorship_policy_invalid"

        if rule.get("required") is True and not sponsors:
            return "sponsorship_required"

        min_sponsors = rule.get("min_sponsors")
        if min_sponsors is not None:
            if (
                not isinstance(min_sponsors, int)
                or isinstance(min_sponsors, bool)
                or min_sponsors < 0
            ):
                return "sponsorship_policy_invalid"
            if len(sponsors) < min_sponsors:
                return "sponsorship_cardinality"

        max_sponsors = rule.get("max_sponsors")
        if max_sponsors is not None:
            if (
                not isinstance(max_sponsors, int)
                or isinstance(max_sponsors, bool)
                or max_sponsors < 0
            ):
                return "sponsorship_policy_invalid"
            if len(sponsors) > max_sponsors:
                return "sponsorship_cardinality"

        if rule.get("sponsor_type") != "founding_member":
            return "sponsorship_policy_invalid"

        if any(sponsor not in eligible_sponsor_set for sponsor in sponsors):
            return "sponsorship_not_eligible"

        if any(sponsor not in participant_orgs for sponsor in sponsors):
            return "sponsorship_not_envelope_participant"

    if sponsors and org_iss not in sponsors:
        return "sponsorship_issuer_not_in_set"

    return None


@app.post("/mint_ect", response_model=MintResp)
def mint_ect(request: Request, req: MintReq):
    org_iss = _minting_org(request)

    sub = req.sub.strip()
    actor_type = req.actor_type.strip()
    if not sub:
        raise HTTPException(400, "invalid_sub")
    # actor_type is retained as attested metadata; authority comes from capabilities.
    if actor_type not in {"human", "agent"}:
        raise HTTPException(400, "unsupported_actor_type")

    envelope = load_active_envelope(req.envelope_id)

    nbf = iso_to_epoch(req.nbf)
    requested_exp = iso_to_epoch(req.exp)
    envelope_exp = int(envelope.get("valid_until") or envelope.get("exp"))
    exp = min(requested_exp, envelope_exp)
    if nbf > exp:
        raise HTTPException(400, "ect_invalid_time_window")

    cap_profiles = list(dict.fromkeys(req.cap_profiles))
    sponsors = list(req.sponsors or [])
    sponsorship_reason = _sponsorship_validation_reason(
        cap_profiles,
        sponsors,
        org_iss,
        envelope,
    )
    if sponsorship_reason:
        raise HTTPException(400, sponsorship_reason)

    caps = pick_caps(_policy, cap_profiles)
    if not caps:
        raise HTTPException(400, "selected profiles produce empty capability set")

    jkt = rfc7638_thumbprint_okp_ed25519(req.holder_pub_b64)
    payload = {
        "iss": ISS,
        "aud": _aud,
        "iat": now_epoch(),
        "nbf": nbf,
        "exp": exp,
        "sub": sub,
        "actor_type": actor_type,
        "org_iss": org_iss,
        "policy": {
            "policy_id": _policy["meta"]["policy_id"],
            "manifest_id": _policy["meta"]["manifest_id"],
            "policy_hash": _policy_hash,
        },
        "envelope_id": req.envelope_id,
        "cnf": {"jkt": jkt},
        "cap_profiles": cap_profiles,
        "cap": caps,
    }
    if sponsors:
        payload["sponsors"] = sponsors

    headers = {"alg": _alg, "kid": ORG_KEY_KID, "typ": "JWT"}
    ect_jws = jwt.encode(payload, _org_priv_pem, algorithm=_alg, headers=headers)
    return MintResp(ect_jws=ect_jws, policy_hash=_policy_hash, alg=_alg, kid=ORG_KEY_KID)

# -----------------------------------------------
# POST /admission/check
# ----------------------------------------------

def _requester_binding_result(allow: bool, reason: Optional[str]) -> str:
    if allow or reason in {
        "reserved_tissue",
        "capability_violation",
        "capability_scope_exceeded",
    }:
        return "verified"
    if reason in {"missing_dpop", "missing_jti"} or str(reason or "").startswith("dpop_"):
        return "failed"
    return "not_evaluated"


def _ect_fingerprint(authorization: Optional[str]) -> Optional[str]:
    if not authorization or not authorization.startswith("ECT "):
        return None
    token = authorization.split(" ", 1)[1].strip()
    return sha256_b64u(token.encode("utf-8")) if token else None

def emit_decision_record(
    body: ProbeReq,
    result: ProbeResp,
    authorization: Optional[str],
) -> tuple[str, float, float, float]:
    decision_id = "decision-" + uuid.uuid4().hex
    reason = result.reason or "capability_match"
    identity = _verified_ect_identity.get() or {}
    record = {
        "artifact_type": "fcac_admission_decision",
        "schema_version": "1.0",
        "decision_id": decision_id,
        "timestamp": now_epoch(),
        "allow_or_deny": "ALLOW" if result.allow else "DENY",
        "decision_reason": reason,
        "requester_binding_result": _requester_binding_result(
            result.allow,
            result.reason,
        ),
        "sub": identity.get("sub"),
        "actor_type": identity.get("actor_type"),
        "org_iss": identity.get("org_iss"),
        "sponsors": identity.get("sponsors", []),
        "cap_profiles": identity.get("cap_profiles", []),
        "requested_action": body.action,
        "requested_purpose": body.purpose,
        "requested_tissue_classes": body.requested_tissues,
        "approved_research_collaboration": body.envelope_id,
        "related_model_run_when_applicable": body.run_id,
        "policy_hash": _policy_hash,
        "request_jti": body.jti,
        "request": {
            "envelope_id": body.envelope_id,
            "run_id": body.run_id,
            "resource": body.resource,
            "action": body.action,
            "purpose": body.purpose,
            "requested_tissues": body.requested_tissues,
            "agg": body.agg,
            "pii": body.pii,
            "contact": body.contact,
            "derivative_representation": body.derivative_representation,
            "governed_value_id": body.governed_value_id,
        },
        "presented_ect_sha256": _ect_fingerprint(authorization),
    }

    emit_start = _ns()
    sign_start = _ns()
    signed_record = sign_artifact(record)
    sign_ms = _ms(_ns() - sign_start)

    persist_start = _ns()
    _write_json_atomic(
        DECISIONS_DIR / f"{decision_id}.json",
        signed_record,
    )
    persist_ms = _ms(_ns() - persist_start)
    emit_ms = _ms(_ns() - emit_start)
    return decision_id, sign_ms, persist_ms, emit_ms


def _bench_return(token_ms, pop_start_ns, full_start_ns, allow: bool, reason: str):
    pop_ms  = _ms(_ns() - pop_start_ns) if pop_start_ns is not None else None
    full_ms = _ms(_ns() - full_start_ns)
    if BENCH:
        _bench_add({
            "token_verify_ms": token_ms,
            "pop_verify_ms": pop_ms,
            "cap_match_ms": None,
            "sign_record_ms": None,
            "persist_record_ms": None,
            "emit_record_ms": None,
            "full_check_ms": full_ms,
            "allow": allow,
            "reason": reason,
        })
    return ProbeResp(allow=allow, reason=reason)


async def _probe_impl(
    request: Request,
    body: ProbeReq,
    authorization: Optional[str],
    dpop_header: Optional[str],
    dpop_nonce: Optional[str],
) -> ProbeResp:
    
    _verified_ect_identity.set(None)
    t0 = _ns()
    token_ms = pop_ms = cap_ms = None

    # 1) ECT
    if not authorization or not authorization.startswith("ECT "):
        if BENCH: _bench_add({"full_check_ms": _ms(_ns()-t0), "allow": False, "reason": "missing_ect"})

        return ProbeResp(allow=False, reason="missing_ect")
    ect_jws = authorization.split(" ", 1)[1].strip()

    t = _ns()
    try:
        ect = jwt.decode(
            ect_jws,
            _org_pub,
            algorithms=["ES256", "ES384", "ES512", "RS256"],
            options={
                "require": [
                    "iss", "nbf", "exp", "policy", "cnf", "cap",
                    "cap_profiles", "envelope_id", "sub", "actor_type", "org_iss",
                ],
                "verify_aud": False,
            },
        )
    except Exception as e:
        token_ms = _ms(_ns() - t)
        if BENCH: _bench_add({"token_verify_ms": token_ms, "full_check_ms": _ms(_ns()-t0),
                              "allow": False, "reason": f"ect_sig_or_claims:{e}"})

        return ProbeResp(allow=False, reason=f"ect_sig_or_claims:{e}")
    token_ms = _ms(_ns() - t)

    if ect.get("iss") != ISS:
        return _bench_return(token_ms, None, t0, False, "iss_mismatch")
    if ect.get("aud") != _aud:
        return _bench_return(token_ms, None, t0, False, "aud_mismatch")

    now = now_epoch()
    if not (ect["nbf"] <= now <= ect["exp"]):
        return _bench_return(token_ms, None, t0, False, "ect_time_window")

    ect_policy = ect.get("policy")
    if not isinstance(ect_policy, dict):
        return _bench_return(token_ms, None, t0, False, "ect_policy_invalid")

    if POLICY_ALLOWLIST and ect_policy.get("policy_hash") not in POLICY_ALLOWLIST:
        return _bench_return(token_ms, None, t0, False, "policy_hash_not_allowed")

    if ect.get("envelope_id") != body.envelope_id:
        return _bench_return(token_ms, None, t0, False, "envelope_mismatch")

    # The ECT remains valid only while its governing envelope remains active.
    try:
        envelope = load_active_envelope(body.envelope_id)
    except HTTPException as exc:
        return _bench_return(token_ms, None, t0, False, str(exc.detail))

    ect_policy_hash = str(ect_policy.get("policy_hash") or "")
    if ect_policy_hash != envelope.get("policy_hash"):
        return _bench_return(
            token_ms, None, t0, False,
            "ect_envelope_policy_mismatch",
        )

    envelope_exp = int(envelope.get("valid_until") or envelope.get("exp"))
    if int(ect.get("exp", 0)) > envelope_exp:
        return _bench_return(
            token_ms, None, t0, False,
            "ect_exp_exceeds_envelope",
        )

    cap_profiles = ect.get("cap_profiles")
    sponsors_claim = ect.get("sponsors")
    sponsorship_reason = _sponsorship_validation_reason(
        cap_profiles,
        sponsors_claim,
        str(ect.get("org_iss") or ""),
        envelope,
    )
    if sponsorship_reason:
        return _bench_return(
            token_ms, None, t0, False,
            sponsorship_reason,
        )

    verified_sponsors = list(sponsors_claim or [])

    # Preserve identity only after the ECT has passed the complete governed
    # validation path. Decision evidence consumes these already-verified claims
    # and must not perform a second token verification.
    _verified_ect_identity.set({
        "sub": ect.get("sub"),
        "actor_type": ect.get("actor_type"),
        "org_iss": ect.get("org_iss"),
        "sponsors": verified_sponsors,
        "cap_profiles": list(cap_profiles),
    })

    # 2) DPoP
    if not dpop_header:
        if BENCH: _bench_add({"token_verify_ms": token_ms, "full_check_ms": _ms(_ns()-t0),
                               "allow": False, "reason": "missing_dpop"})
            
        return ProbeResp(allow=False, reason="missing_dpop")
    if body.jti is None:
        if BENCH: _bench_add({"token_verify_ms": token_ms, "full_check_ms": _ms(_ns()-t0),
                              "allow": False, "reason": "missing_jti"})
            
        return ProbeResp(allow=False, reason="missing_jti")

    t = _ns()
    try:
        parts = dpop_header.split(".")
        if len(parts) != 3:
            return _bench_return(token_ms, t, t0, False, "dpop_format:not_jws_compact")

        hdr = json.loads(b64u_to_bytes(parts[0]).decode("utf-8"))
        pl = json.loads(b64u_to_bytes(parts[1]).decode("utf-8"))
        sig = b64u_to_bytes(parts[2])

        if hdr.get("typ") != "dpop+jwt":
            return _bench_return(token_ms, t, t0, False, "dpop_typ")
        
        if hdr.get("alg") != "EdDSA":
            return _bench_return(token_ms, t, t0, False, "dpop_alg")

        jwk = hdr.get("jwk") or {}
        if jwk.get("kty") != "OKP" or jwk.get("crv") != "Ed25519" or "x" not in jwk:
            return _bench_return(token_ms, t, t0, False, "dpop_jwk")

        
        vk = signing.VerifyKey(b64u_to_bytes(jwk["x"]))
        signing_input = f"{parts[0]}.{parts[1]}".encode("ascii")
        vk.verify(signing_input, sig)

    except Exception as e:
        return _bench_return(token_ms, t, t0, False, f"dpop_verify:{e}")

    # htm/htu/nonce/jti/iat/envelope_id
    try:
        htm = str(pl.get("htm", "")).upper()
        htu = str(pl.get("htu", ""))
        jti = str(pl.get("jti", ""))
        nonce_claim = str(pl.get("nonce", ""))
        proof_envelope_id = str(pl.get("envelope_id", ""))

        if "iat" not in pl:
            return _bench_return(token_ms, t, t0, False, "dpop_iat_missing")

        iat_claim = pl.get("iat")
        if not isinstance(iat_claim, int) or isinstance(iat_claim, bool):
            return _bench_return(token_ms, t, t0, False, "dpop_iat_invalid")

        dpop_now = now_epoch()
        if iat_claim > dpop_now + DPOP_CLOCK_SKEW_SECONDS:
            return _bench_return(token_ms, t, t0, False, "dpop_iat_future")

        if dpop_now - iat_claim > DPOP_MAX_AGE_SECONDS:
            return _bench_return(token_ms, t, t0, False, "dpop_iat_stale")

        if htm != request.method.upper():
            return _bench_return(token_ms, t, t0, False, "dpop_htm_mismatch")

        # Reconstruct request URL as seen by the client (proxy-aware)
        xfp = request.headers.get("x-forwarded-proto") or request.url.scheme
        host = request.headers.get("host") or request.url.netloc
        path = request.url.path
        req_htu = f"{xfp}://{host}{path}"

        if htu != req_htu:
            return _bench_return(token_ms, t, t0, False, "dpop_htu_mismatch")

        if jti != body.jti:
            return _bench_return(token_ms, t, t0, False, "dpop_jti_mismatch")

        if proof_envelope_id != body.envelope_id:
            return _bench_return(
                token_ms, t, t0, False,
                "dpop_envelope_mismatch"
            )

        if (dpop_nonce or "") != nonce_claim:
            return _bench_return(token_ms, t, t0, False, "dpop_nonce_mismatch")

    except Exception as e:
        return _bench_return(token_ms, t, t0, False, f"dpop_claims:{e}")
    
    pop_ms = _ms(_ns() - t)

    # bind DPoP key to ECT cnf.jkt
    if ect.get("cnf", {}).get("jkt") != rfc7638_thumbprint_okp_ed25519(jwk["x"]):
        return _bench_return(token_ms, t, t0, False, "dpop_binding_mismatch")

    # A valid DPoP presentation is single-use. Redis SET NX + EX makes the
    # check atomic across concurrent requests and bounds replay state to the
    # proof freshness window.
    replay_key = (
        "fcac:dpop:jti:"
        + hashlib.sha256(jti.encode("utf-8")).hexdigest()
    )
    try:
        r = await get_redis()
        first_use = await r.set(
            replay_key,
            "1",
            ex=DPOP_REPLAY_TTL_SECONDS,
            nx=True,
        )
    except Exception:
        return _bench_return(
            token_ms, t, t0, False,
            "dpop_replay_store_unavailable",
        )

    if not first_use:
        return _bench_return(token_ms, t, t0, False, "dpop_replay")

    # 3) constitutional reserved-tissue rule
    reserved_tissues = set(
        _policy.get("caveats", {}).get("reserved_pathology_labels", [])
    )
    if reserved_tissues.intersection(body.requested_tissues):
        return _bench_return(token_ms, t, t0, False, "reserved_tissue")

    if body.action == "consume_derivative":
        value_id = str(body.governed_value_id or "")
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", value_id):
            return _bench_return(
                token_ms,
                t,
                t0,
                False,
                "governed_value_id_required",
            )

    # 4) tuple match
    t = _ns()
    req_tuple = {
        "envelope_id": body.envelope_id,
        "run_id": body.run_id,
        "resource": body.resource,
        "action": body.action,
        "purpose": body.purpose,
        "requested_tissues": body.requested_tissues,
        "agg": body.agg,
        "pii": body.pii,
        "contact": body.contact,
        "derivative_representation": body.derivative_representation,
        "governed_value_id": body.governed_value_id,
    }

    failure_reason = "capability_violation"
    for cap in ect.get("cap", []):
        matched, reason = cap_match_result(cap, req_tuple)
        if matched:
            cap_ms = _ms(_ns() - t)
            if BENCH: _bench_add({"token_verify_ms": token_ms, "pop_verify_ms": pop_ms, "cap_match_ms": cap_ms,
                                  "full_check_ms": _ms(_ns()-t0), "allow": True})

            return ProbeResp(allow=True)

        if reason == "capability_scope_exceeded":
            failure_reason = reason

    cap_ms = _ms(_ns() - t)
    if BENCH: _bench_add({"token_verify_ms": token_ms, "pop_verify_ms": pop_ms, "cap_match_ms": cap_ms,
                          "full_check_ms": _ms(_ns()-t0), "allow": False, "reason": failure_reason})

    return ProbeResp(allow=False, reason=failure_reason)


@app.post("/admission/check", response_model=ProbeResp)
async def admission_check(
    request: Request,
    authorization: Optional[str] = Header(None, alias="Authorization"),
    dpop_header: Optional[str] = Header(None, alias="DPoP"),
    dpop_nonce: Optional[str] = Header(None, alias="X-DPoP-Nonce"),
):
    full_start = _ns()
    _bench_begin_request()
    
    try:
        body_json = await request.json()
        body_model = ProbeReq(**body_json)
    except Exception as e:
        raise HTTPException(400, f"invalid_probe_request:{e}")

    result = await _probe_impl(
        request,
        body_model,
        authorization,
        dpop_header,
        dpop_nonce,
    )
    decision_id, sign_ms, persist_ms, emit_ms = emit_decision_record(
        body_model,
        result,
        authorization,
    )
    result.decision_id = decision_id

    _bench_finalize_request({
        "decision_id": decision_id,
        "record_emitted": True,
        "sign_record_ms": sign_ms,
        "persist_record_ms": persist_ms,
        "emit_record_ms": emit_ms,
        "full_check_ms": _ms(_ns() - full_start),
    })
    return result


# ---------------------------------------------------------------------
# Mode 1A guest-contributor aperture
# ---------------------------------------------------------------------
@app.post("/admission/guest-contribution", response_model=ProbeResp)
async def guest_contribution_admission(
    request: Request,
    authorization: Optional[str] = Header(None, alias="Authorization"),
    dpop_header: Optional[str] = Header(None, alias="DPoP"),
    dpop_nonce: Optional[str] = Header(None, alias="X-DPoP-Nonce"),
):
    """Evaluate the pre-declared guest-contributor capability, optionally for one run."""
    full_start = _ns()
    _bench_begin_request()

    try:
        payload = await request.json()
        if not isinstance(payload, dict):
            raise ValueError("body_must_be_object")

        allowed_fields = {"envelope_id", "run_id", "requested_tissues", "jti"}
        unexpected = sorted(set(payload) - allowed_fields)
        if unexpected:
            raise ValueError("unexpected_fields:" + ",".join(unexpected))

        envelope_id = payload.get("envelope_id")
        run_id = payload.get("run_id")
        requested_tissues = payload.get("requested_tissues")
        jti = payload.get("jti")

        if not isinstance(envelope_id, str) or not envelope_id.strip():
            raise ValueError("invalid_envelope_id")
        if run_id is not None and (
            not isinstance(run_id, str) or not run_id.strip()
        ):
            raise ValueError("invalid_run_id")
        if (
            not isinstance(requested_tissues, list)
            or not requested_tissues
            or not all(
                isinstance(tissue, str) and tissue
                for tissue in requested_tissues
            )
        ):
            raise ValueError("invalid_requested_tissues")
        if not isinstance(jti, str) or not jti:
            raise ValueError("invalid_jti")
    except Exception as exc:
        raise HTTPException(
            400,
            f"invalid_guest_contribution_request:{exc}",
        ) from exc

    class GuestContributionProbe:
        # Internal compatibility view for the unchanged verification core.
        resource = "pathmnist-colon-pathology"
        action = "submit_update"
        purpose = "federated_training"
        agg = None
        pii = None
        contact = None
        derivative_representation = None

        def __init__(self):
            self.envelope_id = envelope_id
            self.run_id = (
                run_id.strip() if isinstance(run_id, str) else None
            )
            self.requested_tissues = requested_tissues
            self.jti = jti

    body_model = GuestContributionProbe()

    result = await _probe_impl(
        request,
        body_model,
        authorization,
        dpop_header,
        dpop_nonce,
    )

    # Pinch the generic machinery to the declared guest-contributor grade.
    if result.allow:
        identity = _verified_ect_identity.get() or {}
        profiles = set(identity.get("cap_profiles") or [])
        if (
            identity.get("actor_type") != "human"
            or "capset:pathmnist_guest_contributor" not in profiles
        ):
            result = ProbeResp(
                allow=False,
                reason="capability_violation",
            )

    decision_id, sign_ms, persist_ms, emit_ms = emit_decision_record(
        body_model,
        result,
        authorization,
    )
    result.decision_id = decision_id

    _bench_finalize_request({
        "decision_id": decision_id,
        "record_emitted": True,
        "sign_record_ms": sign_ms,
        "persist_record_ms": persist_ms,
        "emit_record_ms": emit_ms,
        "full_check_ms": _ms(_ns() - full_start),
    })
    return result


# =============================================================================
# Entrypoint
# =============================================================================

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("app:app", host="0.0.0.0", port=int(os.environ.get("PORT", "9000")))
