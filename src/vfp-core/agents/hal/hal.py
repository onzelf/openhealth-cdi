#!/usr/bin/env python3

import base64
import hashlib
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import urllib.error
import urllib.request

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


import io
from PIL import Image

IDENTITY_DIR = Path(
    os.getenv("HAL_IDENTITY_DIR", "/var/lib/hal/identity")
)
PORT = int(os.getenv("HAL_PORT", "8088"))
DPOP_HTU = os.getenv(
    "DPOP_HTU",
    "https://verifier.local/admission/check",
)
MINT_PROOF_HTU = os.getenv(
    "MINT_PROOF_HTU",
    "urn:openhealth:issuer:mint",
)
HUB_URL = os.getenv(
    "HUB_URL",
    "http://fc-hub:8080",
).rstrip("/")

OPENAI_ENV_FILE = Path(
    os.getenv("OPENAI_ENV_FILE", "/run/secrets/openai.env")
)
OPENAI_MODEL = os.getenv("OPENAI_MODEL", "gpt-5.6-luna")
OPENAI_RESPONSES_URL = "https://api.openai.com/v1/responses"

ALLOWED_REASONING_ACTIONS = {
    "no_transform",
    "blur_image",
    "minimal_statistics",
    "refuse",
}

PRIVATE_KEY_PATH = IDENTITY_DIR / "holder.key"
PUBLIC_JWK_PATH = IDENTITY_DIR / "holder.jwk"
JKT_PATH = IDENTITY_DIR / "holder.jkt"
ECT_STATE_PATH = IDENTITY_DIR / "holder_ect.json"

HAL_AUTHORITY_OPERATIONS = {
    ("pathmnist-colon-pathology", "bounded_inference", "bounded_model_inference"),
    ("pathmnist-colon-pathology", "unbind", "policy_authorized_derivation"),
}


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def load_or_create_private_key() -> Ed25519PrivateKey:
    IDENTITY_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(IDENTITY_DIR, 0o700)

    if PRIVATE_KEY_PATH.exists():
        private_key = serialization.load_pem_private_key(
            PRIVATE_KEY_PATH.read_bytes(),
            password=None,
        )

        if not isinstance(private_key, Ed25519PrivateKey):
            raise RuntimeError("holder.key is not an Ed25519 private key")

        os.chmod(PRIVATE_KEY_PATH, 0o600)
        return private_key

    private_key = Ed25519PrivateKey.generate()

    pem = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )

    fd = os.open(
        PRIVATE_KEY_PATH,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        0o600,
    )

    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(pem)
    except Exception:
        PRIVATE_KEY_PATH.unlink(missing_ok=True)
        raise

    return private_key


def write_public_identity(private_key: Ed25519PrivateKey) -> None:
    public_raw = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )

    jwk = {
        "crv": "Ed25519",
        "kty": "OKP",
        "x": b64url(public_raw),
    }

    canonical = json.dumps(
        jwk,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")

    jkt = b64url(hashlib.sha256(canonical).digest())

    PUBLIC_JWK_PATH.write_text(
        json.dumps(jwk, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    JKT_PATH.write_text(jkt + "\n", encoding="utf-8")

    os.chmod(PUBLIC_JWK_PATH, 0o644)
    os.chmod(JKT_PATH, 0o644)


def encode_json(value: dict) -> str:
    return b64url(
        json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    )


def sign_dpop(private_key: Ed25519PrivateKey, payload: dict) -> str:
    # Holder identity is established by the key bound into the ECT.
    # The caller does not select a subject name for this signer.
    htu = str(payload.get("htu") or "").strip()
    if htu not in {DPOP_HTU, MINT_PROOF_HTU}:
        raise ValueError("invalid_htu")
    if payload.get("htm") != "POST":
        raise ValueError("invalid_htm")

    jti = str(payload.get("jti") or "").strip()
    nonce = str(payload.get("nonce") or "").strip()
    envelope_id = str(payload.get("envelope_id") or "").strip()
    if not jti or not nonce or not envelope_id:
        raise ValueError("missing_dpop_binding")

    jwk = json.loads(PUBLIC_JWK_PATH.read_text(encoding="utf-8"))
    header = encode_json({
        "typ": "dpop+jwt",
        "alg": "EdDSA",
        "jwk": jwk,
    })
    claims_payload = {
        "htu": htu,
        "htm": "POST",
        "iat": int(time.time()),
        "jti": jti,
        "nonce": nonce,
        "envelope_id": envelope_id,
    }
    request_hash = str(payload.get("request_hash") or "").strip()
    if request_hash:
        claims_payload["request_hash"] = request_hash
    claims = encode_json(claims_payload)
    signing_input = f"{header}.{claims}".encode("ascii")
    signature = b64url(private_key.sign(signing_input))
    return f"{header}.{claims}.{signature}"


def decode_compact_claims(token: str) -> dict:
    try:
        parts = token.split(".")
        if len(parts) != 3:
            raise ValueError("not_compact_jws")
        encoded = parts[1] + "=" * (-len(parts[1]) % 4)
        claims = json.loads(base64.urlsafe_b64decode(encoded).decode("utf-8"))
    except Exception as exc:
        raise ValueError("invalid_ect") from exc
    if not isinstance(claims, dict):
        raise ValueError("invalid_ect")
    return claims


def load_cached_ect(envelope_id: str) -> str:
    if not ECT_STATE_PATH.is_file():
        return ""
    try:
        state = json.loads(ECT_STATE_PATH.read_text(encoding="utf-8"))
        ect = str(state.get("ect") or "").strip()
        claims = decode_compact_claims(ect)
        if str(claims.get("sub") or "") != "Hal":
            return ""
        if str(claims.get("envelope_id") or "") != envelope_id:
            return ""
        if int(claims.get("exp") or 0) <= int(time.time()) + 5:
            return ""
        return ect
    except Exception:
        return ""


def store_ect(ect: str) -> None:
    claims = decode_compact_claims(ect)
    state = {
        "principal": "Hal",
        "envelope_id": claims.get("envelope_id"),
        "exp": claims.get("exp"),
        "ect": ect,
    }
    tmp = ECT_STATE_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, ECT_STATE_PATH)
    os.chmod(ECT_STATE_PATH, 0o600)


def ensure_holder_ect(
    private_key: Ed25519PrivateKey,
    envelope_id: str,
) -> str:
    cached = load_cached_ect(envelope_id)
    if cached:
        return cached

    mint_proof = sign_dpop(
        private_key,
        {
            "htu": MINT_PROOF_HTU,
            "htm": "POST",
            "jti": "mint-" + b64url(os.urandom(18)),
            "nonce": "mint-" + b64url(os.urandom(18)),
            "envelope_id": envelope_id,
        },
    )

    request = urllib.request.Request(
        HUB_URL + "/administration/holders/Hal/mint-ect",
        data=json.dumps({
            "envelope_id": envelope_id,
            "holder_dpop": mint_proof,
        }).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            payload = json.loads(response.read())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(
            f"hal_ect_mint_http_{exc.code}:{detail[:300]}"
        ) from exc
    except urllib.error.URLError as exc:
        raise RuntimeError("hal_ect_mint_relay_unreachable") from exc

    ect = str(payload.get("ect") or "").strip()
    if not ect:
        raise RuntimeError("hal_ect_mint_missing_ect")
    claims = decode_compact_claims(ect)
    if str(claims.get("sub") or "") != "Hal":
        raise RuntimeError("hal_ect_subject_mismatch")
    if str(claims.get("envelope_id") or "") != envelope_id:
        raise RuntimeError("hal_ect_envelope_mismatch")
    if int(claims.get("exp") or 0) <= int(time.time()):
        raise RuntimeError("hal_ect_already_expired")
    store_ect(ect)
    return ect


def governed_request_hash(request_payload: dict) -> str:
    canonical = json.dumps(
        request_payload,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")
    return "sha256:" + hashlib.sha256(canonical).hexdigest()


def make_authority_presentation(
    private_key: Ed25519PrivateKey,
    payload: dict,
) -> dict:
    if str(payload.get("principal") or "").strip() != "Hal":
        raise ValueError("principal_mismatch")

    envelope_id = str(payload.get("envelope_id") or "").strip()
    run_id = str(payload.get("run_id") or "").strip()
    resource = str(payload.get("resource") or "").strip()
    action = str(payload.get("action") or "").strip()
    purpose = str(payload.get("purpose") or "").strip()
    requested_tissues = payload.get("requested_tissues")

    if not envelope_id or not run_id:
        raise ValueError("authority_context_required")
    if (resource, action, purpose) not in HAL_AUTHORITY_OPERATIONS:
        raise ValueError("authority_operation_not_supported")
    if (
        not isinstance(requested_tissues, list)
        or len(requested_tissues) != 1
        or not str(requested_tissues[0]).strip()
    ):
        raise ValueError("single_requested_tissue_required")

    exact_request = {
        "envelope_id": envelope_id,
        "run_id": run_id,
        "resource": resource,
        "action": action,
        "purpose": purpose,
        "requested_tissues": [str(requested_tissues[0])],
    }
    for name in (
        "derivative_representation",
        "governed_value_id",
        "governed_value",
    ):
        if name in payload and payload[name] is not None:
            exact_request[name] = payload[name]

    ect = ensure_holder_ect(private_key, envelope_id)
    request_hash = governed_request_hash(exact_request)
    nonce = "nonce-" + b64url(os.urandom(18))
    jti = "jti-" + b64url(os.urandom(18))
    dpop = sign_dpop(
        private_key,
        {
            "htu": DPOP_HTU,
            "htm": "POST",
            "jti": jti,
            "nonce": nonce,
            "envelope_id": envelope_id,
            "request_hash": request_hash,
        },
    )

    return {
        "principal": "Hal",
        "envelope_id": envelope_id,
        "authorization": f"ECT {ect}",
        "dpop": dpop,
        "nonce": nonce,
        "jti": jti,
        "request_hash": request_hash,
        "request": exact_request,
    }


def load_openai_api_key() -> str:
    key = os.getenv("OPENAI_API_KEY", "").strip()
    if key:
        return key

    if not OPENAI_ENV_FILE.is_file():
        raise RuntimeError("openai_api_key_not_configured")
    
    try:
        lines = OPENAI_ENV_FILE.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise RuntimeError("openai_api_key_not_configured") from exc

    for raw_line in lines:
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue

        name, value = line.split("=", 1)

        if name.strip() == "OPENAI_API_KEY":
            key = value.strip().strip('"').strip("'")
            if key:
                return key

    raise RuntimeError("openai_api_key_not_configured")


def extract_openai_text(response: dict) -> str:
    for item in response.get("output", []):
        if item.get("type") != "message":
            continue

        for content in item.get("content", []):
            if content.get("type") == "output_text":
                text = str(content.get("text") or "").strip()
                if text:
                    return text

    raise RuntimeError("openai_response_has_no_text")


def decide_with_llm(payload: dict) -> dict:
    available = payload.get("available_actions")

    if not isinstance(available, list) or not available:
        raise ValueError("available_actions_required")

    available = [str(action).strip() for action in available]

    unknown = set(available) - ALLOWED_REASONING_ACTIONS
    if unknown:
        raise ValueError(
            "unknown_available_action:" + ",".join(sorted(unknown))
        )

    context = {
        "request_goal": payload.get("request_goal"),
        "requester_context": payload.get("requester_context", {}),
        "resource_context": payload.get("resource_context", {}),
        "available_actions": available,
    }

    prompt = f"""
You are the reasoning runtime of Hal, a governed computational participant.

You do not grant authority and you do not modify governance rules.
Your task is only to select the most appropriate intended action from the
finite set supplied in available_actions.

The same resource may require different actions in different governed
contexts. Do not infer permissions from a person's name. Base the choice on
the supplied requester and resource context.

General interpretation:

- no_transform means the requester may receive the source representation
  without a derivative transformation.
- blur_image means a visual derivative is appropriate when unrestricted
  source disclosure is not permitted but a visual derivative is useful.
- minimal_statistics means only bounded aggregate/statistical information
  should be returned.
- refuse means none of the available actions appropriately satisfies the
  request.

Return exactly one JSON object and no Markdown:

{{"action":"<one available action>","rationale":"<brief reason>"}}

Context:

{json.dumps(context, sort_keys=True)}
""".strip()

    request_body = json.dumps({
        "model": OPENAI_MODEL,
        "input": prompt,
        "max_output_tokens": 180,
    }).encode("utf-8")

    request = urllib.request.Request(
        OPENAI_RESPONSES_URL,
        data=request_body,
        headers={
            "Authorization": f"Bearer {load_openai_api_key()}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw_response = json.loads(response.read())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(
            f"openai_http_{exc.code}:{detail[:300]}"
        ) from exc
    except urllib.error.URLError as exc:
        raise RuntimeError("openai_unreachable") from exc

    text = extract_openai_text(raw_response)

    try:
        decision = json.loads(text)
    except json.JSONDecodeError:
        return {
            "action": "refuse",
            "rationale": "reasoning_runtime_returned_invalid_json",
            "model": OPENAI_MODEL,
            "fallback": True,
        }

    action = str(decision.get("action") or "").strip()

    if action not in available:
        return {
            "action": "refuse",
            "rationale": "reasoning_runtime_selected_unavailable_action",
            "model": OPENAI_MODEL,
            "fallback": True,
        }

    return {
        "action": action,
        "rationale": str(decision.get("rationale") or "").strip(),
        "model": OPENAI_MODEL,
        "fallback": False,
    }


def blur_image_derivative(payload: dict) -> dict:
    image_b64 = str(payload.get("image_b64") or "").strip()
    if not image_b64:
        raise ValueError("image_b64_required")

    if image_b64.startswith("data:"):
        if "," not in image_b64:
            raise ValueError("invalid_image_data_url")
        image_b64 = image_b64.split(",", 1)[1]

    try:
        raw = base64.b64decode(image_b64, validate=True)
    except Exception as exc:
        raise ValueError("invalid_image_base64") from exc

    try:
        with Image.open(io.BytesIO(raw)) as source:
            source.load()
            image = source.convert("RGB")
    except Exception as exc:
        raise ValueError("invalid_image") from exc

    coarse = image.resize((7, 7), Image.Resampling.BOX)
    derivative = coarse.resize((28, 28), Image.Resampling.NEAREST)

    buffer = io.BytesIO()
    derivative.save(buffer, format="PNG")
    derivative_bytes = buffer.getvalue()

    return {
        "derivative_representation":
            "blurred_image_with_qualitative_accuracy",
        "mime_type": "image/png",
        "image_b64": base64.b64encode(
            derivative_bytes
        ).decode("ascii"),
        "width": derivative.width,
        "height": derivative.height,
        "sha256": hashlib.sha256(derivative_bytes).hexdigest(),
    }

def make_handler(private_key: Ed25519PrivateKey):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, _format, *_args):
            return

        def send_json(self, status: int, payload: dict) -> None:
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/health":
                self.send_json(200, {"status": "ok", "principal": "Hal"})
                return
            if self.path == "/identity":
                self.send_json(200, {
                    "principal": "Hal",
                    "jwk": json.loads(PUBLIC_JWK_PATH.read_text(encoding="utf-8")),
                    "jkt": JKT_PATH.read_text(encoding="utf-8").strip(),
                })
                return
            self.send_json(404, {"detail": "not_found"})


        def do_POST(self):
            try:
                length = int(self.headers.get("Content-Length", "0"))
                payload = json.loads(self.rfile.read(length) or b"{}")
            except (ValueError, json.JSONDecodeError) as exc:
                self.send_json(400, {"detail": str(exc)})
                return

            if self.path == "/decide":
                try:
                    decision = decide_with_llm(payload)
                except ValueError as exc:
                    self.send_json(400, {"detail": str(exc)})
                    return
                except RuntimeError as exc:
                    self.send_json(502, {"detail": str(exc)})
                    return

                self.send_json(200, decision)
                return

            if self.path == "/tools/blur":
                try:
                    derivative = blur_image_derivative(payload)
                except ValueError as exc:
                    self.send_json(400, {"detail": str(exc)})
                    return

                self.send_json(200, derivative)
                return

            if self.path == "/authority/present":
                try:
                    presentation = make_authority_presentation(
                        private_key,
                        payload,
                    )
                except ValueError as exc:
                    self.send_json(400, {"detail": str(exc)})
                    return
                except RuntimeError as exc:
                    self.send_json(502, {"detail": str(exc)})
                    return
                self.send_json(200, presentation)
                return

            self.send_json(404, {"detail": "not_found"})           

    return Handler


def main() -> None:
    private_key = load_or_create_private_key()
    write_public_identity(private_key)

    print(
        f"Hal identity ready jkt={JKT_PATH.read_text().strip()}",
        flush=True,
    )
    print(
        f"Hal authority endpoint ready on agent-edge port {PORT}",
        flush=True,
    )

    server = ThreadingHTTPServer(("0.0.0.0", PORT), make_handler(private_key))
    server.serve_forever(poll_interval=0.5)


if __name__ == "__main__":
    main()
