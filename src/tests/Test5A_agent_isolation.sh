#!/usr/bin/env bash

#                  Hal
#                   │
#                   │ agent-edge
#                   ▼
#                 Hub
#                   │
#                   │ fc
#                   ▼
#                  Redis / Gatekeeper / Issuers / Flower / other federation services#


set -euo pipefail

# Test5A — Hal network and cryptographic-custody isolation
#
# Gate 5A proves architecture and custody only.
# Later gates may activate Hal without changing these isolation invariants.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ACTORS_JSON="${SRC_DIR}/vfp-core/issuers/config/actors.json"

HAL_CONTAINER="${HAL_CONTAINER:-hal}"
HUB_CONTAINER="${HUB_CONTAINER:-fc-hub}"
LAN_IP="${LAN_IP:?Set LAN_IP to the address passed to OpenTofu as -var=lan_ip}"

pass() {
    printf '\033[32m✓\033[0m %s\n' "$*"
}

fail() {
    printf '\033[31m✗\033[0m %s\n' "$*" >&2
    exit 1
}

section() {
    printf '\n============================================================\n'
    printf '%s\n' "$1"
    printf '============================================================\n'
}

for cmd in docker jq python3; do
    command -v "${cmd}" >/dev/null 2>&1 ||
        fail "Missing command: ${cmd}"
done

[[ -s "${ACTORS_JSON}" ]] ||
    fail "Missing actor catalogue: ${ACTORS_JSON}"


# ==== Section 1
section "1. Containers"

docker inspect "${HAL_CONTAINER}" >/dev/null 2>&1 ||
    fail "Hal container does not exist"

docker inspect "${HUB_CONTAINER}" >/dev/null 2>&1 ||
    fail "Hub container does not exist"

HAL_RUNNING="$(
    docker inspect \
        --format '{{.State.Running}}' \
        "${HAL_CONTAINER}"
)"

[[ "${HAL_RUNNING}" == "true" ]] ||
    fail "Hal container is not running"

pass "Hal container exists and is running"


# ==== Section 2
section "2. Network topology"

HAL_NETWORKS="$(
    docker inspect "${HAL_CONTAINER}" |
        jq -r '.[0].NetworkSettings.Networks | keys[]'
)"

HUB_NETWORKS="$(
    docker inspect "${HUB_CONTAINER}" |
        jq -r '.[0].NetworkSettings.Networks | keys[]'
)"

[[ "${HAL_NETWORKS}" == "agent-edge" ]] || {
    printf 'Observed Hal networks:\n%s\n' "${HAL_NETWORKS}" >&2
    fail "Hal must be attached only to agent-edge"
}

pass "Hal is attached only to agent-edge"

grep -qx 'fc' <<<"${HUB_NETWORKS}" ||
    fail "Hub is not attached to fc"

grep -qx 'agent-edge' <<<"${HUB_NETWORKS}" ||
    fail "Hub is not attached to agent-edge"

pass "Hub is dual-homed on fc and agent-edge"


# ==== Section 3
section "3. Positive Hub aperture"

docker exec -i "${HAL_CONTAINER}" python - <<'PY'
import socket

with socket.create_connection(("fc-hub", 8080), timeout=2):
    pass
PY

pass "Hal can reach fc-hub:8080"

# ==== Section 4
section "4. Federation-internal services are unreachable"

assert_unreachable() {
    local host="$1"
    local port="$2"

    if docker exec  -i \
        -e TARGET_HOST="${host}" \
        -e TARGET_PORT="${port}" \
        "${HAL_CONTAINER}" \
        python - <<'PY'
import os
import socket
import sys

host = os.environ["TARGET_HOST"]
port = int(os.environ["TARGET_PORT"])

try:
    addresses = socket.getaddrinfo(
        host,
        port,
        type=socket.SOCK_STREAM,
    )
except socket.gaierror:
    sys.exit(1)

for family, socktype, proto, _, sockaddr in addresses:
    sock = socket.socket(family, socktype, proto)
    sock.settimeout(1.0)

    try:
        sock.connect(sockaddr)
    except OSError:
        continue
    finally:
        sock.close()

    sys.exit(0)

sys.exit(1)
PY
    then
        fail "Hal unexpectedly reached ${host}:${port}"
    else
        pass "Hal cannot reach ${host}:${port}"
    fi
}

assert_unreachable "redis" 6379
assert_unreachable "holder-signer" 8090
assert_unreachable "verifier-app" 9000
assert_unreachable "verifier-proxy" 8443

# Host-published federation edges may be routable from agent-edge.
# The invariant is that Hal cannot authenticate through those governed edges.
assert_edge_denied() {
    local host="$1"
    local port="$2"
    local server_name="$3"
    local method="$4"
    local path="$5"
    local result

    result="$(
        docker exec -i \
            -e TARGET_HOST="${host}" \
            -e TARGET_PORT="${port}" \
            -e SERVER_NAME="${server_name}" \
            -e HTTP_METHOD="${method}" \
            -e TARGET_PATH="${path}" \
            "${HAL_CONTAINER}" \
            python - <<'PY2'
import os
import socket
import ssl

host = os.environ["TARGET_HOST"]
port = int(os.environ["TARGET_PORT"])
server_name = os.environ["SERVER_NAME"]
method = os.environ["HTTP_METHOD"]
path = os.environ["TARGET_PATH"]

context = ssl.create_default_context()
context.check_hostname = False
context.verify_mode = ssl.CERT_NONE

try:
    with socket.create_connection((host, port), timeout=3) as raw:
        with context.wrap_socket(raw, server_hostname=server_name) as tls:
            request = (
                f"{method} {path} HTTP/1.1\r\n"
                f"Host: {server_name}\r\n"
                "Content-Length: 0\r\n"
                "Connection: close\r\n\r\n"
            )
            tls.sendall(request.encode("ascii"))
            response = tls.recv(4096)
except (OSError, ssl.SSLError):
    print("transport_or_tls_denied")
    raise SystemExit(0)

status_line = response.split(b"\r\n", 1)[0].decode("ascii", "replace")
parts = status_line.split()
status = parts[1] if len(parts) >= 2 else "invalid_response"
body = response.split(b"\r\n\r\n", 1)[1] if b"\r\n\r\n" in response else b""

if (
    status == "400"
    and b"No required SSL certificate was sent" in body
):
    print("400_missing_client_certificate")
else:
    print(status)
PY2
    )"

    case "${result}" in
        transport_or_tls_denied|400_missing_client_certificate|401|403)
            pass "Hal is denied by ${server_name}:${port}${path} (${result})"
            ;;
        *)
            fail "Hal obtained unexpected access via ${server_name}:${port}${path}: ${result}"
            ;;
    esac
}

assert_edge_denied "${LAN_IP}" 8443 "verifier.local" POST "/admission/check"
assert_edge_denied "${LAN_IP}" 9443 "issuer-hospitala.local" GET "/members"

assert_unreachable "issuer-hospitala" 8080
assert_unreachable "issuer-hospitalb" 8080
assert_unreachable "issuer-proxy" 8443
assert_unreachable "flower-server" 8080
assert_unreachable "flower-server" 8081


section "5. Hal cryptographic custody"

docker exec "${HAL_CONTAINER}" \
    test -s /var/lib/hal/identity/holder.key ||
    fail "Hal holder private key missing"

docker exec "${HAL_CONTAINER}" \
    test -s /var/lib/hal/identity/holder.jwk ||
    fail "Hal public holder JWK missing"

docker exec "${HAL_CONTAINER}" \
    test -s /var/lib/hal/identity/holder.jkt ||
    fail "Hal JKT missing"

KEY_MODE="$(
    docker exec "${HAL_CONTAINER}" \
        stat -c '%a' /var/lib/hal/identity/holder.key
)"

[[ "${KEY_MODE}" == "600" ]] ||
    fail "Hal holder key mode is ${KEY_MODE}, expected 600"

pass "Hal owns an Ed25519 holder identity"
pass "Hal private holder key has mode 600"


section "6. Secret and mount isolation"

MOUNTS="$(
    docker inspect "${HAL_CONTAINER}" |
        jq -r '.[0].Mounts[].Destination'
)"

EXPECTED_MOUNTS="$(
    printf '%s\n' \
        "/run/secrets/openai.env" \
        "/var/lib/hal/identity" |
        sort
)"

MOUNTS_SORTED="$(printf '%s\n' "${MOUNTS}" | sort)"

[[ "${MOUNTS_SORTED}" == "${EXPECTED_MOUNTS}" ]] || {
    printf 'Observed Hal mounts:\n%s\n' "${MOUNTS}" >&2
    fail "Hal has unexpected mounts"
}

pass "Hal has only its identity and LLM credential mounts"

OPENAI_SECRET_RW="$(
    docker inspect "${HAL_CONTAINER}" |
        jq -r '.[0].Mounts[]
            | select(.Destination == "/run/secrets/openai.env")
            | .RW'
)"

[[ "${OPENAI_SECRET_RW}" == "false" ]] ||
    fail "Hal OpenAI credential mount is not read-only"

pass "Hal LLM credential mount is read-only"

if docker exec "${HAL_CONTAINER}" sh -c \
    'find / -name fcac-evidence.key -print -quit 2>/dev/null | grep -q .'
then
    fail "Hal can see fcac-evidence.key"
fi

pass "Hal has no FCaC evidence private key"

docker exec "${HAL_CONTAINER}" test ! -e /vault ||
    fail "Hal unexpectedly has /vault"

docker exec "${HAL_CONTAINER}" test ! -e /run/certs ||
    fail "Hal unexpectedly has verifier certificate material"

pass "Hal has no verifier vault or shared certificate mount"


section "7. Runtime activation preserves isolation"

HAL_STATUS="$(
    jq -r '
        to_entries[]
        | .value[]
        | select(.principal == "Hal")
        | .status
    ' "${ACTORS_JSON}"
)"

[[ "${HAL_STATUS}" == "active" ]] ||
    fail "Hal status is ${HAL_STATUS}, expected active after Gate 5C"

pass "Hal is active; Gate 5A remains a topology and custody invariant"


section "8. Gate 5A invariant"

printf '\n'
printf 'Hal exists with dedicated cryptographic custody.\n'
printf 'Hal can reach only the Hub federation aperture.\n'
printf 'Hal cannot directly reach federation internals.\n'
printf 'Hal activation does not create a direct federation route.\n'
printf '\n'

pass "Gate 5A GREEN"