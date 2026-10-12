#!/usr/bin/env bash
# TestA9_actor_type_confusion.sh
#
# Attack:
#   Test whether Hub-local actor classification can create a security-authority
#   path that does not exist for the same principal when classified as human.
#
# Security invariant:
#   The Hub is passive with respect to security authority.
#   A Hub-local actor_type value must not cause the Hub to synthesize holder
#   proofs, acquire principal credentials, or otherwise originate authority.
#
# Method:
#   1. Verify Bob is human in the deployed Hub actor catalogue.
#   2. Remote-injection control. Send actor_type=agent and dpop_signer_url in
#      the request body. They must not change Bob's custody semantics.
#   3. Start an isolated shadow Hub with the same code and issuer/verifier
#      dependencies, but with a copied actor catalogue in which ONLY the
#      Hub-local Bob entry is changed from human to agent and given a controlled
#      audit signer URL. The institutional issuer configuration is untouched.
#   4. Submit the exact same Bob mint request without Bob holder proof.
#   5. Observe whether the shadow Hub calls the controlled signer.
#
# A9 is CONFIRMED if changing only the Hub-local actor_type classification
# causes the Hub to invoke a signer for Bob. Successful Bob ECT issuance is not
# required. Signer invocation alone proves that Hub-local classification
# activates a proof-synthesis security path and violates Hub passivity.
#
# A9 is NOT CONFIRMED if the altered Hub still requires externally constituted
# Bob holder proof and never invokes the controlled signer.
#
# Verdict contract:
#   rc=0   A9 NOT CONFIRMED / Hub remains passive
#   rc=1   A9 CONFIRMED / Hub-local actor_type activated proof synthesis
#   rc=2   INCONCLUSIVE / attack did not isolate the invariant
#   rc=70  HARNESS ERROR
#
# Usage:
#   ./TestA9_actor_type_confusion.sh <active-envelope-id>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ENVELOPE_ID="${1:-}"
[[ -n "${ENVELOPE_ID}" ]] || {
    printf 'Usage: %s <active-envelope-id>\n' "$0" >&2
    exit 70
}

LIVE_HUB_URL="${LIVE_HUB_URL:-http://127.0.0.1:8080}"
LIVE_HUB_CONTAINER="${LIVE_HUB_CONTAINER:-fc-hub}"
HAL_CONTAINER="${HAL_CONTAINER:-hal}"

SHADOW_HUB_CONTAINER="${SHADOW_HUB_CONTAINER:-fc-hub-a9}"
AUDIT_SIGNER_CONTAINER="${AUDIT_SIGNER_CONTAINER:-a9-signer}"
SHADOW_PORT="${SHADOW_PORT:-18080}"
SHADOW_HUB_URL="http://127.0.0.1:${SHADOW_PORT}"

FC_NETWORK="${FC_NETWORK:-fc}"
AGENT_NETWORK="${AGENT_NETWORK:-agent-edge}"

ACTOR_CATALOG="${SRC_DIR}/vfp-core/issuers/config/actors.json"
HOSPITAL_B_ENTITLEMENTS="${SRC_DIR}/vfp-core/issuers/config/hospital_b_entitlements.json"

CA="${SRC_DIR}/vfp-governance/verifier/certs/ca.crt"
HUB_CRT="${SRC_DIR}/vfp-governance/verifier/certs/hub.crt"
HUB_KEY="${SRC_DIR}/vfp-governance/verifier/certs/hub.key"
LIVE_VAULT="${SRC_DIR}/vfp-governance/verifier/vault"

TMP="$(mktemp -d)"
SIGNER_LOG="${TMP}/signer_calls.jsonl"

SHADOW_STARTED=0
SIGNER_STARTED=0

pass() {
    printf '\033[32m✓\033[0m %s\n' "$*"
}

note() {
    printf '\033[36m·\033[0m %s\n' "$*"
}

section() {
    printf '\n============================================================\n'
    printf '%s\n' "$1"
    printf '============================================================\n'
}

blocked() {
    printf '\n\033[32mA9 NOT CONFIRMED / BLOCKED\033[0m\n'
    printf '%s\n' "$*"
    exit 0
}

confirmed() {
    printf '\n\033[31mA9 CONFIRMED\033[0m\n'
    printf '%s\n' "$*"
    exit 1
}

inconclusive() {
    printf '\n\033[33m? A9 INCONCLUSIVE\033[0m %s\n' "$*" >&2
    exit 2
}

error() {
    printf '\n\033[31m! A9 HARNESS ERROR\033[0m %s\n' "$*" >&2
    exit 70
}

cleanup() {
    local rc=$?
    set +e

    if [[ "${SHADOW_STARTED}" == "1" ]]; then
        docker rm -f "${SHADOW_HUB_CONTAINER}" >/dev/null 2>&1
    fi

    if [[ "${SIGNER_STARTED}" == "1" ]]; then
        docker rm -f "${AUDIT_SIGNER_CONTAINER}" >/dev/null 2>&1
    fi

    rm -rf "${TMP}"
    exit "${rc}"
}
trap cleanup EXIT

for cmd in curl jq docker python3 cp; do
    command -v "${cmd}" >/dev/null 2>&1 ||
        error "Missing command: ${cmd}"
done

for file in \
    "${ACTOR_CATALOG}" \
    "${HOSPITAL_B_ENTITLEMENTS}" \
    "${CA}" "${HUB_CRT}" "${HUB_KEY}"; do
    [[ -s "${file}" ]] || error "Missing file: ${file}"
done

[[ -d "${LIVE_VAULT}" ]] ||
    error "Missing Hub vault directory: ${LIVE_VAULT}"

docker inspect "${LIVE_HUB_CONTAINER}" >/dev/null 2>&1 ||
    error "Live Hub container is unavailable"

docker inspect "${HAL_CONTAINER}" >/dev/null 2>&1 ||
    error "Hal container is unavailable"

docker network inspect "${FC_NETWORK}" >/dev/null 2>&1 ||
    error "Missing Docker network: ${FC_NETWORK}"

docker network inspect "${AGENT_NETWORK}" >/dev/null 2>&1 ||
    error "Missing Docker network: ${AGENT_NETWORK}"

if docker inspect "${SHADOW_HUB_CONTAINER}" >/dev/null 2>&1; then
    error "Container already exists: ${SHADOW_HUB_CONTAINER}"
fi

if docker inspect "${AUDIT_SIGNER_CONTAINER}" >/dev/null 2>&1; then
    error "Container already exists: ${AUDIT_SIGNER_CONTAINER}"
fi

wait_http() {
    local url="$1"
    local label="$2"

    for _ in $(seq 1 30); do
        if curl -fsS "${url}/health" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    error "${label} did not become healthy"
}

select_envelope() {
    local base_url="$1"

    curl -fsS \
        -X POST \
        -H 'content-type: application/json' \
        -d '{}' \
        "${base_url}/administration/envelopes/${ENVELOPE_ID}/select" \
        >/dev/null ||
        error "Could not select envelope ${ENVELOPE_ID} on ${base_url}"

    curl -fsS "${base_url}/administration/boundary" |
        jq -e \
            --arg e "${ENVELOPE_ID}" '
            .selected_envelope_id == $e
            and (
                [.envelopes[]
                 | select(.envelope_id == $e and .bound == true)]
                | length == 1
            )
            ' >/dev/null ||
        error "Envelope ${ENVELOPE_ID} is not selected and bound on ${base_url}"
}

mint_without_holder_proof() {
    local base_url="$1"
    local body="$2"
    local outfile="$3"

    curl -sS \
        -o "${outfile}" \
        -w '%{http_code}' \
        -X POST \
        -H 'content-type: application/json' \
        -d "${body}" \
        "${base_url}/administration/holders/Bob/mint-ect"
}

signer_call_count() {
    if [[ ! -s "${SIGNER_LOG}" ]]; then
        printf '0'
        return
    fi
    wc -l <"${SIGNER_LOG}" | tr -d ' '
}

section "1. Verify authoritative baseline"

BOB_ACTOR_TYPE="$(
    jq -r '
        .["org://HospitalB"][]?
        | select(.principal == "Bob")
        | .actor_type // empty
    ' "${ACTOR_CATALOG}" |
    head -n1
)"

[[ "${BOB_ACTOR_TYPE}" == "human" ]] || {
    jq '.["org://HospitalB"]' "${ACTOR_CATALOG}" >&2
    error "Baseline Hub catalogue does not classify Bob as human"
}

# The issuer-side Hospital B entitlement file must remain untouched by A9.
# Bob has no issuer-side agent classification in the current configuration.
ISSUER_BOB_ACTOR_TYPE="$(
    jq -r '
        (.actor_types // {})["Bob"] // "human"
    ' "${HOSPITAL_B_ENTITLEMENTS}"
)"

[[ "${ISSUER_BOB_ACTOR_TYPE}" == "human" ]] || {
    jq . "${HOSPITAL_B_ENTITLEMENTS}" >&2
    error "Hospital B issuer already classifies Bob as agent"
}

pass "Hub baseline classifies Bob as human"
pass "Hospital B issuer independently classifies Bob as human"

select_envelope "${LIVE_HUB_URL}"
pass "Active envelope is selected and bound"

section "2. Remote actor_type injection control"

REMOTE_BODY="$(
    jq -nc \
        --arg e "${ENVELOPE_ID}" '
        {
          envelope_id:$e,
          actor_type:"agent",
          dpop_signer_url:"http://a9-signer:8088"
        }
        '
)"

REMOTE_FILE="${TMP}/remote_injection.json"
REMOTE_STATUS="$(
    mint_without_holder_proof \
        "${LIVE_HUB_URL}" \
        "${REMOTE_BODY}" \
        "${REMOTE_FILE}"
)"

REMOTE_DETAIL="$(jq -r '.detail // empty' "${REMOTE_FILE}" 2>/dev/null || true)"

case "${REMOTE_STATUS}" in
    400)
        [[ "${REMOTE_DETAIL}" == "holder_mint_proof_required" ]] || {
            cat "${REMOTE_FILE}" | jq . >&2 || true
            inconclusive \
                "Remote injection returned HTTP 400 for unrelated reason: ${REMOTE_DETAIL:-unknown}"
        }
        pass "Caller-supplied actor_type did not override Bob's human custody"
        ;;
    422)
        pass "Caller-supplied actor_type fields were rejected by request validation"
        ;;
    200)
        cat "${REMOTE_FILE}" | jq . >&2 || true
        confirmed \
            "Remote request fields alone changed Bob custody semantics and produced a mint response."
        ;;
    *)
        cat "${REMOTE_FILE}" | jq . >&2 || true
        inconclusive "Remote injection returned unexpected HTTP ${REMOTE_STATUS}"
        ;;
esac

section "3. Build controlled signer and altered Hub catalogue"

cp "${ACTOR_CATALOG}" "${TMP}/actors-control.json"

jq '
    (.["org://HospitalB"][] | select(.principal == "Bob") | .actor_type) = "agent"
    |
    (.["org://HospitalB"][] | select(.principal == "Bob") | .dpop_signer_url)
        = "http://a9-signer:8088"
' "${ACTOR_CATALOG}" >"${TMP}/actors-attack.json" ||
    error "Could not construct altered actor catalogue"

jq -e '
    [.["org://HospitalB"][]?
     | select(
         .principal == "Bob"
         and .actor_type == "agent"
         and .dpop_signer_url == "http://a9-signer:8088"
       )]
    | length == 1
' "${TMP}/actors-attack.json" >/dev/null ||
    error "Altered actor catalogue does not contain the intended Bob mutation"

# Confirm that no issuer configuration was altered by the test.
[[ "$(
    jq -r '(.actor_types // {})["Bob"] // "human"' \
        "${HOSPITAL_B_ENTITLEMENTS}"
)" == "human" ]] ||
    error "Hospital B issuer classification changed unexpectedly"

cat >"${TMP}/a9_signer.py" <<'PY'
import base64
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

LOG = os.environ.get("A9_SIGNER_LOG", "/audit/signer_calls.jsonl")
KEY = Ed25519PrivateKey.generate()


def b64u(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def compact_json(value: dict) -> str:
    return b64u(
        json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    )


PUB = b64u(
    KEY.public_key().public_bytes(
        encoding=Encoding.Raw,
        format=PublicFormat.Raw,
    )
)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, _format, *_args):
        return

    def send_json(self, status: int, payload: dict):
        raw = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path == "/health":
            self.send_json(200, {"status": "ok"})
            return
        self.send_json(404, {"detail": "not_found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)

        try:
            payload = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            self.send_json(400, {"detail": "invalid_json"})
            return

        if self.path != "/dpop/sign":
            self.send_json(404, {"detail": "not_found"})
            return

        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as handle:
            handle.write(
                json.dumps(
                    {
                        "time": time.time(),
                        "path": self.path,
                        "payload": payload,
                    },
                    sort_keys=True,
                )
                + "\n"
            )

        header = {
            "typ": "dpop+jwt",
            "alg": "EdDSA",
            "jwk": {
                "kty": "OKP",
                "crv": "Ed25519",
                "x": PUB,
            },
        }

        claims = {
            "htu": payload.get("htu"),
            "htm": payload.get("htm"),
            "iat": int(time.time()),
            "jti": payload.get("jti"),
            "nonce": payload.get("nonce"),
            "envelope_id": payload.get("envelope_id"),
        }

        h = compact_json(header)
        p = compact_json(claims)
        signing_input = f"{h}.{p}".encode("ascii")
        sig = b64u(KEY.sign(signing_input))

        self.send_json(
            200,
            {
                "dpop": f"{h}.{p}.{sig}",
            },
        )


ThreadingHTTPServer(("0.0.0.0", 8088), Handler).serve_forever()
PY

HAL_IMAGE="$(
    docker inspect \
        --format '{{.Config.Image}}' \
        "${HAL_CONTAINER}"
)"
[[ -n "${HAL_IMAGE}" ]] ||
    error "Cannot determine Hal image"

: >"${SIGNER_LOG}"

docker run -d \
    --name "${AUDIT_SIGNER_CONTAINER}" \
    --network "${AGENT_NETWORK}" \
    -e A9_SIGNER_LOG=/audit/signer_calls.jsonl \
    -v "${TMP}:/audit" \
    --entrypoint python \
    "${HAL_IMAGE}" \
    /audit/a9_signer.py \
    >/dev/null

SIGNER_STARTED=1

for _ in $(seq 1 20); do
    if docker exec "${AUDIT_SIGNER_CONTAINER}" \
        python - <<'PY' >/dev/null 2>&1
import urllib.request
urllib.request.urlopen("http://127.0.0.1:8088/health", timeout=1).read()
PY
    then
        break
    fi
    sleep 1
done

if ! docker exec "${AUDIT_SIGNER_CONTAINER}" \
    python - <<'PY' >/dev/null 2>&1
import urllib.request
urllib.request.urlopen("http://127.0.0.1:8088/health", timeout=2).read()
PY
then
    error "Controlled A9 signer did not become healthy"
fi

pass "Controlled audit signer is ready"
pass "Only the Hub-local Bob classification has been altered"

section "4. Start isolated shadow Hub with altered classification"

HUB_IMAGE="$(
    docker inspect \
        --format '{{.Config.Image}}' \
        "${LIVE_HUB_CONTAINER}"
)"
[[ -n "${HUB_IMAGE}" ]] ||
    error "Cannot determine Hub image"

docker inspect "${LIVE_HUB_CONTAINER}" |
    jq -r '.[0].Config.Env[]' >"${TMP}/hub.env" ||
    error "Cannot copy live Hub environment"

mkdir -p "${TMP}/vault"
cp -a "${LIVE_VAULT}/." "${TMP}/vault/" ||
    error "Cannot create isolated Hub vault copy"

docker run -d \
    --name "${SHADOW_HUB_CONTAINER}" \
    --network "${FC_NETWORK}" \
    --env-file "${TMP}/hub.env" \
    -p "127.0.0.1:${SHADOW_PORT}:8080" \
    -v "${CA}:/run/certs/ca.crt:ro" \
    -v "${HUB_CRT}:/run/certs/hub.crt:ro" \
    -v "${HUB_KEY}:/run/certs/hub.key:ro" \
    -v "${TMP}/vault:/vault" \
    -v "${TMP}/actors-attack.json:/app/config/actors.json:ro" \
    "${HUB_IMAGE}" \
    >/dev/null

SHADOW_STARTED=1

docker network connect \
    "${AGENT_NETWORK}" \
    "${SHADOW_HUB_CONTAINER}" ||
    error "Cannot attach shadow Hub to agent network"

wait_http "${SHADOW_HUB_URL}" "Shadow Hub"

# A fresh Hub has an empty in-memory backend registry.  Do not call /select,
# because that would attempt to bind the live Flower backend again.  Instead,
# copy only the live backend registration into the isolated Hub.  The shadow
# Hub can then observe the backend's existing bound_envelope through /status.
LIVE_FLOWER_BACKEND="$(
    curl -fsS "${LIVE_HUB_URL}/backend/list" |
        jq -c '
            .backends[]?
            | select(.backend_type == "flower_server")
        ' |
        head -n1
)"

[[ -n "${LIVE_FLOWER_BACKEND}" ]] ||
    error "Live Hub has no registered flower_server backend"

SHADOW_BACKEND_RESPONSE="$(
    curl -fsS         -X POST         -H 'content-type: application/json'         -d "${LIVE_FLOWER_BACKEND}"         "${SHADOW_HUB_URL}/backend/register"
)" || error "Could not register existing Flower backend with shadow Hub"

jq -e '
    .status == "registered"
    and .backend.backend_type == "flower_server"
' <<<"${SHADOW_BACKEND_RESPONSE}" >/dev/null || {
    printf '%s\n' "${SHADOW_BACKEND_RESPONSE}" | jq . >&2 || true
    error "Shadow Hub did not accept Flower backend registration"
}

SHADOW_BOUNDARY="$(
    curl -fsS "${SHADOW_HUB_URL}/administration/boundary"
)" || error "Cannot read shadow Hub boundary"

jq -e     --arg e "${ENVELOPE_ID}" '
    .selected_envelope_id == $e
    and (
        [.envelopes[]
         | select(.envelope_id == $e and .bound == true)]
        | length == 1
    )
' <<<"${SHADOW_BOUNDARY}" >/dev/null || {
    printf '%s\n' "${SHADOW_BOUNDARY}" | jq . >&2
    inconclusive         "Shadow Hub does not observe the live backend as bound to ${ENVELOPE_ID}"
}

pass "Shadow Hub observes the existing bound envelope without rebinding it"

jq -e '
    [.holders[]?
     | select(.principal == "Bob" and .actor_type == "agent")]
    | length == 1
' <<<"${SHADOW_BOUNDARY}" >/dev/null || {
    printf '%s\n' "${SHADOW_BOUNDARY}" | jq . >&2
    inconclusive "Shadow Hub did not load Bob as agent"
}

pass "Shadow Hub loaded the altered Bob actor_type"

section "5. Attack — same Bob mint request, no Bob holder proof"

ATTACK_BODY="$(
    jq -nc --arg e "${ENVELOPE_ID}" '{envelope_id:$e}'
)"

ATTACK_FILE="${TMP}/attack_response.json"
BEFORE_CALLS="$(signer_call_count)"

ATTACK_STATUS="$(
    mint_without_holder_proof \
        "${SHADOW_HUB_URL}" \
        "${ATTACK_BODY}" \
        "${ATTACK_FILE}"
)"

AFTER_CALLS="$(signer_call_count)"

printf 'Shadow Hub response HTTP %s:\n' "${ATTACK_STATUS}"
jq . "${ATTACK_FILE}" 2>/dev/null || cat "${ATTACK_FILE}"

printf '\nControlled signer calls:\n'
if [[ -s "${SIGNER_LOG}" ]]; then
    jq -s . "${SIGNER_LOG}"
else
    printf '[]\n'
fi

if (( AFTER_CALLS > BEFORE_CALLS )); then
    if [[ "${ATTACK_STATUS}" == "200" ]] &&
       jq -e '.ready == true and .principal == "Bob"' \
           "${ATTACK_FILE}" >/dev/null 2>&1; then
        confirmed \
            "Changing only Hub-local actor_type caused the Hub to synthesize a Bob proof path and acquire Bob authority."
    fi

    confirmed \
        "Changing only Hub-local actor_type caused the Hub to invoke a signer for Bob. The issuer may still reject the resulting proof, but Hub passivity is already violated."
fi

ATTACK_DETAIL="$(jq -r '.detail // empty' "${ATTACK_FILE}" 2>/dev/null || true)"

if [[ "${ATTACK_STATUS}" == "400" &&
      "${ATTACK_DETAIL}" == "holder_mint_proof_required" ]]; then
    blocked \
        "Even with Bob locally reclassified as agent, the Hub required externally constituted Bob holder proof and never invoked the signer."
fi

inconclusive \
    "Altered classification did not invoke the signer, but the response was not holder_mint_proof_required (HTTP ${ATTACK_STATUS}, detail=${ATTACK_DETAIL:-none})."
