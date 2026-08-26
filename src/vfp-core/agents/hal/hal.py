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
from PIL import Image, ImageFilter

IDENTITY_DIR = Path(
    os.getenv("HAL_IDENTITY_DIR", "/var/lib/hal/identity")
)
PORT = int(os.getenv("HAL_PORT", "8088"))
DPOP_HTU = os.getenv(
    "DPOP_HTU",
    "https://verifier.local/admission/check",
)

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
    if payload.get("sub") != "Hal":
        raise ValueError("invalid_subject")
    if payload.get("htu") != DPOP_HTU:
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
    claims = encode_json({
        "htu": DPOP_HTU,
        "htm": "POST",
        "iat": int(time.time()),
        "jti": jti,
        "nonce": nonce,
        "envelope_id": envelope_id,
    })
    signing_input = f"{header}.{claims}".encode("ascii")
    signature = b64url(private_key.sign(signing_input))
    return f"{header}.{claims}.{signature}"


def load_openai_api_key() -> str:
    key = os.getenv("OPENAI_API_KEY", "").strip()
    if key:
        return key

    if not OPENAI_ENV_FILE.exists():
        raise RuntimeError("openai_api_key_not_configured")

    for raw_line in OPENAI_ENV_FILE.read_text(encoding="utf-8").splitlines():
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

    # PathMNIST is only 28x28. A relatively strong Gaussian blur is
    # intentional so the derivative is visibly distinct in the PoC.
    derivative = image.filter(ImageFilter.GaussianBlur(radius=0.8))

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

            if self.path != "/dpop/sign":
                self.send_json(404, {"detail": "not_found"})
                return

            try:
                dpop = sign_dpop(private_key, payload)
            except ValueError as exc:
                self.send_json(400, {"detail": str(exc)})
                return

            self.send_json(200, {
                "dpop": dpop,
                "jkt": JKT_PATH.read_text(encoding="utf-8").strip(),
            })           

    return Handler


def main() -> None:
    private_key = load_or_create_private_key()
    write_public_identity(private_key)

    print(
        f"Hal identity ready jkt={JKT_PATH.read_text().strip()}",
        flush=True,
    )
    print(
        f"Hal holder signer ready on agent-edge port {PORT}",
        flush=True,
    )

    server = ThreadingHTTPServer(("0.0.0.0", PORT), make_handler(private_key))
    server.serve_forever(poll_interval=0.5)


if __name__ == "__main__":
    main()
