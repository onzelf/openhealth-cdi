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

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa

from nacl.signing import SigningKey
from nacl.encoding import HexEncoder
from nacl import signing

from benchmark import BENCH, BENCH_OUT, _ms, _ns, _bench_add, _bench_flush, _bench_reset
import logging

log = logging.getLogger("verifier")
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

for d in (STATE_DIR, ENVS_DIR, BINDS_DIR, EVENTS_DIR):
    d.mkdir(parents=True, exist_ok=True)

REDIS_URL = os.environ.get("REDIS_URL", "redis://redis:6379/0")
REDIS_CHANNEL_ENVELOPES_CREATED = os.environ.get("FCAC_ENVELOPE_CHANNEL", "fcac:envelopes:created")
redis_client = None

# Enforce nginx mTLS headers for /verify-start by default (matches your previous behavior)
REQUIRE_MTLS_HEADERS = os.environ.get("REQUIRE_MTLS_HEADERS", "true").lower() in ("1", "true", "yes")

# Issuer constants (keep consistent with your test harness)
ISS = os.environ.get("ISS", "http://127.0.0.1:9100")
AUD_FALLBACK = os.environ.get("AUD", "svc:fl-gateway:eu")
ORG_KEY_KID = os.environ.get("ORG_KEY_KID", "HospitalA-key")
ORG_KEY_FILE = os.environ.get("ORG_KEY_FILE", str(FCAC_CERTS_DIR / "HospitalA-admin.key"))  # PEM EC/RSA

# Optional allowlist (comma-separated sha256_b64u policy hashes from compute_policy_hash)
POLICY_ALLOWLIST = {x.strip() for x in os.environ.get("ALLOWED_POLICY_HASHES", "").split(",") if x.strip()}

# KYO
SESSION_TTL = int(os.environ.get("SESSION_TTL", "600"))  # seconds
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
# Envelope decision key (attestation) -  
# =============================================================================

def load_decision_keys():
    kdir = STATE_DIR / "keys"
    kdir.mkdir(exist_ok=True)
    sk_path = kdir / "decision.sk"
    pk_path = kdir / "decision.pk"
    if sk_path.exists():
        sk = SigningKey(bytes.fromhex(sk_path.read_text().strip()))
    else:
        sk = SigningKey.generate()
        sk_path.write_text(sk.encode(HexEncoder).decode())
        pk_path.write_text(sk.verify_key.encode(HexEncoder).decode())
    return sk, sk.verify_key

SK, VK = load_decision_keys()

def attest(decision: str, reason: str, version: str, phash: str, request_body: dict) -> dict:
    ts = int(time.time())
    payload = {
        "ts": ts,
        "decision": decision,
        "reason": reason,
        "policy_version": version,
        "policy_hash": phash,
        "input": request_body,
    }
    sig = SK.sign(json.dumps(payload, sort_keys=True).encode("utf-8")).signature.hex()
    payload["signature"] = sig
    payload["pubkey"] = VK.encode(HexEncoder).decode()
    return payload


# =============================================================================
# Policy loading + hashing (issuer_lite_eddsa semantics)
# =============================================================================

def load_policy() -> Dict[str, Any]:
    pol = _read_json(POLICY_PATH)
    if not pol:
        raise RuntimeError(f"policy.json not found at {POLICY_PATH}")
    for k in ("version", "ops", "cap_profiles", "meta"):
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
        if "cohort" in cap["scope"]:
            if req.get("cohort") not in cap["scope"]["cohort"]:
                return False, "capability_violation"

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
    cohort: Optional[str] = None
    agg: Optional[str] = None
    pii: Optional[bool] = None
    contact: Optional[bool] = None
    jti: Optional[str] = None  # echoed in DPoP signed content

class ProbeResp(BaseModel):
    allow: bool
    reason: Optional[str] = None


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

def _load_env_summary(p: Path):
    try:
        e = json.loads(p.read_text(encoding="utf-8"))
        return {
            "envelope_id": e.get("envelope_id"),
            "state": e.get("state"),
            "exp": e.get("exp") or e.get("valid_until"),
            "policy_hash": e.get("policy_hash"),
            "scope": e.get("scope", {}),
            "allowed_ops": e.get("allowed_ops", []),
            "participants": [pp.get("org") for pp in e.get("participants", [])],
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
    exp = now_epoch() + SESSION_TTL
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
@app.post("/beta/bind/init")
async def bind_init(req: Request):
    b = await req.json()
    bid = "b" + uuid.uuid4().hex[:12]

    # NOTE: envelope side uses policy_hash for binding evidence. Keep it aligned with the current policy.json on disk.
    pol = load_policy()
    ph = "sha256:" + hashlib.sha256(json.dumps(pol, sort_keys=True).encode("utf-8")).hexdigest()

    rec = {
        "bind_id": bid,
        "state": "PENDING",
        "participants": b.get("participants", []),
        "quorum": b.get("quorum", {"k": 2, "n": 2}),
        "scope": b.get("scope", {}),
        "allowed_ops": b.get("allowed_ops", []),
        "approvals": [],
        "policy_hash": ph,
        "ts": now_epoch(),
    }
    bind_save(rec)
    append_event({"bind_init": {"bind_id": bid, "policy_hash": ph}})
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
        "envelope_id": eid,
        "state": "ACTIVE",
        "created_at": now_epoch(),
        "activated_at": now_epoch(),
        "valid_until": now_epoch() + SESSION_TTL,
        "scope": b["scope"],
        "allowed_ops": b["allowed_ops"],
        "participants": b["participants"],
        "policy_hash": b["policy_hash"],
        "quorum": b["quorum"],
        "lineage": [],
        "initiators": [{"session_id": a["session_id"], "org": a["org"]} for a in b["approvals"]],
    }
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
            "allowed_ops": env["allowed_ops"],
            "policy_hash": env["policy_hash"],
            "valid_until": env["valid_until"],
            "participants": [p.get("org") for p in env["participants"]],
            "scope": env.get("scope", {}),
            "created_at": now_epoch(),
        }
        await r.publish(REDIS_CHANNEL_ENVELOPES_CREATED, json.dumps(envelope_event))
        print(f"[gatekeeper] Published envelope creation: {eid}", flush=True)
    except Exception as ex:
        print(f"[gatekeeper] Warning: failed to publish backend assignment: {ex}", flush=True)

    # Attestation (envelope evidence)
    pol = load_policy()
    ph = "sha256:" + hashlib.sha256(json.dumps(pol, sort_keys=True).encode("utf-8")).hexdigest()
    att = attest("PERMIT", "envelope_active", pol.get("version", "1.00"), ph, {"envelope_id": eid, "bind_id": bind_id})

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
    if envelope.get("state") != "ACTIVE":
        raise HTTPException(400, "envelope_not_active")

    valid_until = envelope.get("valid_until") or envelope.get("exp")
    if valid_until is not None and int(valid_until) <= now_epoch():
        raise HTTPException(400, "envelope_expired")

    return envelope


@app.post("/mint_ect", response_model=MintResp)
def mint_ect(req: MintReq):
    load_active_envelope(req.envelope_id)

    caps = pick_caps(_policy, req.cap_profiles)
    if not caps:
        raise HTTPException(400, "selected profiles produce empty capability set")

    jkt = rfc7638_thumbprint_okp_ed25519(req.holder_pub_b64)
    payload = {
        "iss": ISS,
        "aud": _aud,
        "iat": now_epoch(),
        "nbf": iso_to_epoch(req.nbf),
        "exp": iso_to_epoch(req.exp),
        "policy": {
            "policy_id": _policy["meta"]["policy_id"],
            "manifest_id": _policy["meta"]["manifest_id"],
            "policy_hash": _policy_hash,
        },
        "envelope_id": req.envelope_id,
        "cnf": {"jkt": jkt},
        "cap": caps,
    }
    headers = {"alg": _alg, "kid": ORG_KEY_KID, "typ": "JWT"}
    ect_jws = jwt.encode(payload, _org_priv_pem, algorithm=_alg, headers=headers)
    return MintResp(ect_jws=ect_jws, policy_hash=_policy_hash, alg=_alg, kid=ORG_KEY_KID)

# -----------------------------------------------
# POST /admission/check
# ----------------------------------------------

def _bench_return(token_ms, pop_start_ns, full_start_ns, allow: bool, reason: str):
    pop_ms  = _ms(_ns() - pop_start_ns) if pop_start_ns is not None else None
    full_ms = _ms(_ns() - full_start_ns)
    if BENCH:
        _bench_add({
            "token_verify_ms": token_ms,
            "pop_verify_ms": pop_ms,
            "cap_match_ms": None,
            "emit_record_ms": 0.0,
            "full_check_ms": full_ms,
            "allow": allow,
            "reason": reason,
        })
    return ProbeResp(allow=allow, reason=reason)


def _probe_impl(
    request: Request,
    body: ProbeReq,
    authorization: Optional[str],
    dpop_header: Optional[str],
    dpop_nonce: Optional[str],
) -> ProbeResp:
    
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
                "require": ["iss", "nbf", "exp", "policy", "cnf", "cap", "envelope_id"],
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
        return ProbeResp(allow=False, reason="ect_time_window")

    if POLICY_ALLOWLIST and ect["policy"].get("policy_hash") not in POLICY_ALLOWLIST:
        return ProbeResp(allow=False, reason="policy_hash_not_allowed")

    if ect.get("envelope_id") != body.envelope_id:
        return _bench_return(token_ms, None, t0, False, "envelope_mismatch")

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

    # htm/htu/nonce/jti/envelope_id
    try:
        htm = str(pl.get("htm", "")).upper()
        htu = str(pl.get("htu", ""))
        jti = str(pl.get("jti", ""))
        nonce_claim = str(pl.get("nonce", ""))
        proof_envelope_id = str(pl.get("envelope_id", ""))

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

    # 3) constitutional reserved-tissue rule
    reserved_tissues = set(
        _policy.get("caveats", {}).get("reserved_pathology_labels", [])
    )
    if reserved_tissues.intersection(body.requested_tissues):
        return _bench_return(token_ms, t, t0, False, "reserved_tissue")

    # 4) tuple match
    t = _ns()
    req_tuple = {
        "envelope_id": body.envelope_id,
        "run_id": body.run_id,
        "resource": body.resource,
        "action": body.action,
        "purpose": body.purpose,
        "requested_tissues": body.requested_tissues,
        "cohort": body.cohort,
        "agg": body.agg,
        "pii": body.pii,
        "contact": body.contact,
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
    
    try:
        body_json = await request.json()
        body_model = ProbeReq(**body_json)
    except Exception as e:
        raise HTTPException(400, f"invalid_probe_request:{e}")
    return _probe_impl(request, body_model, authorization, dpop_header, dpop_nonce)


# =============================================================================
# Entrypoint
# =============================================================================

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("app:app", host="0.0.0.0", port=int(os.environ.get("PORT", "9000")))
