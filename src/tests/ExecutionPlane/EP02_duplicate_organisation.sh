#!/usr/bin/env bash
# EP02 — duplicate governed organisation at the Flower execution boundary.
#
# Invariant: two independent Flower connections must not be accepted merely
# because both assert the same org_id.  Keep genuine Hospital A connected,
# stop B and C, then connect an unregistered second A.  Any fit instruction
# delivered to the duplicate is an execution-admission failure.
#
# Verdicts: 0 = not reproduced; 1 = vulnerability confirmed;
#           70 = harness/precondition/cleanup failure.
# Usage: ./EP02_duplicate_organisation.sh <active-envelope-id>
#
# The rogue aborts on fit and returns NO model update. The test preserves
# pre-existing run directories, including local-pathmnist-ab-001.
set -euo pipefail

EID="${1:-}"
RUN_ID="${RUN_ID:-local-pathmnist-ab-001}"  # Hub/Flower control-run name
TIMEOUT_S="${TIMEOUT_S:-120}"
ROGUE_CONTAINER=ep02-duplicate-a
TMP="$(mktemp -d)"
MARKER="${TMP}/out/fit-called.json"
INIT_DONE=0
ROGUE_OWNED=0
A_RUNNING=0
B_RUNNING=0
C_RUNNING=0
ATTACK_RUN=""

pass() { printf '\033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
harness_fail() { fail "EP02 HARNESS ERROR — $*"; exit 70; }
is_running() {
    [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" == true ]]
}

container_http() {
    local container="$1" method="$2" url="$3" payload="${4:-}"
    docker exec -i "$container" python - "$method" "$url" "$payload" <<'PY'
import sys
import urllib.request
import urllib.error
method, url, payload = sys.argv[1:]
req = urllib.request.Request(
    url, method=method,
    data=payload.encode() if payload else None,
    headers={"Content-Type": "application/json"} if payload else {},
)
try:
    with urllib.request.urlopen(req, timeout=8) as response:
        print(response.read().decode())
except urllib.error.HTTPError as exc:
    print(exc.read().decode(), file=sys.stderr)
    raise SystemExit(22)
except Exception as exc:
    print(repr(exc), file=sys.stderr)
    raise SystemExit(23)
PY
}
hub_get() { container_http fc-hub GET "http://127.0.0.1:8080$1"; }
hub_post() { container_http fc-hub POST "http://127.0.0.1:8080$1" "${2:-}"; }
flower_status() { container_http flower-server GET "http://127.0.0.1:8081/status"; }

cleanup() {
    local rc=$?
    trap - EXIT
    set +e
    if (( ROGUE_OWNED )); then
        docker rm -f "$ROGUE_CONTAINER" >/dev/null 2>&1 || true
    fi
    if (( INIT_DONE )); then
        # Stop only the control lifecycle that this test initialized.
        hub_post "/experiments/${RUN_ID}/stop" '{}' >/dev/null 2>&1 || true

        # Determine newly allocated artifact run before resetting the backend.
        if [[ -z "$ATTACK_RUN" ]] && is_running flower-server; then
            local st
            st="$(flower_status 2>/dev/null || true)"
            ATTACK_RUN="$(jq -r '.model_run_id // empty' <<<"$st" 2>/dev/null || true)"
        fi

        if is_running flower-server; then
            # Restore the prior envelope/model pointer. Never remove a prior manifest.
            if [[ -f "$TMP/run.json.before" ]]; then
                docker cp "$TMP/run.json.before" \
                    "flower-server:/vault/${EID}/run.json" >/dev/null 2>&1 || rc=70
            elif [[ -n "$EID" ]]; then
                docker exec flower-server rm -f "/vault/${EID}/run.json" \
                    >/dev/null 2>&1 || rc=70
            fi

            # Remove only a new artifact created during EP02, never an existing run.
            if [[ "$ATTACK_RUN" =~ ^local-pathmnist-ab-[0-9]+$ ]] \
               && [[ "$ATTACK_RUN" != "$RUN_ID" ]] \
               && ! grep -Fxq "$ATTACK_RUN" "$TMP/runs.before"; then
                docker exec flower-server rm -rf "/vault/runs/${ATTACK_RUN}" \
                    >/dev/null 2>&1 || rc=70
            fi

            docker restart flower-server >/dev/null 2>&1 || rc=70
            # Confirm the selected envelope is again bound, not merely that
            # the Docker process has restarted.
            local restored=0 boundary
            for _ in $(seq 1 30); do
                boundary="$(hub_get '/administration/boundary' 2>/dev/null || true)"
                if jq -e --arg e "$EID" \
                    --argjson expect_model "$( [[ -f "$TMP/run.json.before" ]] && echo true || echo false )" '
                    .selected_envelope_id == $e and
                    ([.envelopes[]? | select(.envelope_id == $e
                        and .bound == true
                        and (if $expect_model then .model_available == true else true end))]
                     | length == 1)
                ' <<<"$boundary" >/dev/null 2>&1; then
                    restored=1
                    break
                fi
                sleep 1
            done
            (( restored )) || rc=70
        else
            rc=70
        fi
    fi

    # Restore the clients to their original running/stopped states.
    if (( INIT_DONE )); then
        for spec in "flower-client-a:$A_RUNNING" \
                    "flower-client-b:$B_RUNNING" \
                    "flower-client-c:$C_RUNNING"; do
            local name="${spec%%:*}" state="${spec##*:}"
            if [[ "$state" == 1 ]]; then
                docker restart "$name" >/dev/null 2>&1 || rc=70
            else
                docker stop "$name" >/dev/null 2>&1 || rc=70
            fi
        done
    fi
    rm -rf "$TMP"
    if (( rc == 70 )); then
        fail "EP02 cleanup could not fully restore the local runtime"
    fi
    exit "$rc"
}
trap cleanup EXIT

[[ -n "$EID" && "$EID" != *'/'* && "$EID" != *'..'* ]] || \
    harness_fail 'Usage: EP02_duplicate_organisation.sh <active-envelope-id>'
[[ "$RUN_ID" == local-pathmnist-ab-001 ]] || \
    harness_fail 'Use the deployed control run local-pathmnist-ab-001'
for cmd in docker jq python3 grep date; do
    command -v "$cmd" >/dev/null || harness_fail "Missing $cmd"
done
for c in fc-hub flower-server flower-client-a flower-client-b flower-client-c; do
    docker inspect "$c" >/dev/null 2>&1 || harness_fail "Missing container $c"
done
is_running fc-hub && is_running flower-server || \
    harness_fail 'Hub and Flower server must be running'
docker inspect "$ROGUE_CONTAINER" >/dev/null 2>&1 && \
    harness_fail "Container $ROGUE_CONTAINER already exists; refusing to replace it"

# Before touching runtime, verify EID and preserve envelope manifest and run inventory.
BOUNDARY="$(hub_get '/administration/boundary')" || \
    harness_fail 'Cannot read governance boundary'
jq -e --arg e "$EID" '
   .selected_envelope_id == $e and
   ([.envelopes[] | select(.envelope_id == $e and .bound == true)] | length == 1)
' <<<"$BOUNDARY" >/dev/null || harness_fail 'Envelope is not selected and bound'

START_STATE="$(flower_status)" || harness_fail 'Cannot read backend status'
jq -e '.training.status != "running"' <<<"$START_STATE" >/dev/null || \
    harness_fail 'An existing training run is active'

if docker exec flower-server test -f "/vault/${EID}/run.json"; then
    docker cp "flower-server:/vault/${EID}/run.json" "$TMP/run.json.before" || \
        harness_fail 'Cannot preserve existing envelope manifest'
fi

docker exec -i flower-server python - <<'PY' >"$TMP/runs.before"
from pathlib import Path
for d in sorted(Path('/vault/runs').iterdir()):
    if d.is_dir():
        print(d.name)
PY

is_running flower-client-a && A_RUNNING=1
is_running flower-client-b && B_RUNNING=1
is_running flower-client-c && C_RUNNING=1
(( A_RUNNING && B_RUNNING )) || \
    harness_fail 'Both genuine A and B must be running at the outset'
pass 'Preconditions and reference-run preservation checks passed'

# A/B legitimately register through the Hub control plane. Only A should
# remain connected to Flower when the attack starts.
INIT_BODY="$(jq -nc --arg run "$RUN_ID" '{run_id:$run, phase:"AB_BASE", rounds:1, min_clients:2, local_epochs:1}')"
INIT_DONE=1  # Cleanup is required even if initialisation partially succeeds.
INIT="$(hub_post /experiments/initialise "$INIT_BODY")" || \
    harness_fail 'Hub initialisation failed'
jq -e --arg e "$EID" '.status == "initialised" and .active_envelope_id == $e and .backend_bound == true' \
    <<<"$INIT" >/dev/null || harness_fail 'Hub did not initialise a bound AB_BASE lifecycle'

docker restart flower-client-a flower-client-b >/dev/null || \
    harness_fail 'Cannot refresh legitimate A/B Hub registrations'

READY=0
for _ in $(seq 1 40); do
    S="$(hub_get "/experiments/${RUN_ID}/status" 2>/dev/null || true)"
    if jq -e '.registered_client_count >= 2 and .can_start == true' \
        <<<"$S" >/dev/null 2>&1; then READY=1; break; fi
    sleep 1
done
(( READY )) || harness_fail 'Legitimate Hub A/B readiness not established'

# B/C are absent from the actual execution plane; A remains genuine.
docker stop flower-client-b flower-client-c >/dev/null || \
    harness_fail 'Could not remove B/C from Flower execution plane'
docker restart flower-client-a >/dev/null || \
    harness_fail 'Could not restart genuine A'

# A clone of the real client protocol stack bypasses register_with_hub() and
# has no admission material. It writes an independent, local fit marker.
mkdir -p "$TMP/out"
cat >"$TMP/ep02_probe.py" <<'PY'
import json
import os
import sys
import time
from pathlib import Path
import flwr as fl
sys.path.insert(0, '/app')
import client as impl

marker = Path('/audit/out/fit-called.json')
class DuplicateA(impl.FlowerClient):
    def fit(self, parameters, config):
        marker.write_text(json.dumps({
            'event': 'fit_called', 'org_id': impl.ORG_ID,
            'hospital': impl.HOSPITAL, 'pid': os.getpid(),
            'fit_config': dict(config or {}), 'timestamp': time.time(),
        }), encoding='utf-8')
        raise RuntimeError('EP02_PROBE_ABORT: duplicate A selected for fit')

assert impl.HOSPITAL == 'A' and impl.ORG_ID == 'org://HospitalA'
impl.validate_configuration()
impl.validate_cuda_runtime()
probe = DuplicateA()
while not marker.exists():
    try:
        fl.client.start_numpy_client(server_address=impl.SERVER, client=probe)
    except Exception as exc:
        if marker.exists():
            break
        print('EP02_RETRY', repr(exc), flush=True)
    if not marker.exists():
        time.sleep(1)
PY

IMAGE="$(docker inspect -f '{{.Config.Image}}' flower-client-a)"
NETWORK="$(docker inspect -f '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{"\n"}}{{end}}' flower-client-a | head -n1)"
[[ -n "$IMAGE" && -n "$NETWORK" ]] || harness_fail 'Cannot determine client image/network'
# Match the genuine client environment but force the probe onto CPU.
docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' flower-client-a \
    | grep -v '^DEVICE=' >"$TMP/rogue.env"
printf 'DEVICE=cpu\n' >>"$TMP/rogue.env"
ROGUE_OWNED=1
docker run -d --name "$ROGUE_CONTAINER" --network "$NETWORK" \
    --env-file "$TMP/rogue.env" \
    -v "$TMP/ep02_probe.py:/audit/ep02_probe.py:ro" \
    -v "$TMP/out:/audit/out" \
    --entrypoint python "$IMAGE" -u /audit/ep02_probe.py >/dev/null || \
    harness_fail 'Could not start rogue A probe'
pass 'Unregistered duplicate-A Flower connection started'

START="$(hub_post "/experiments/${RUN_ID}/start" '{}')" || \
    harness_fail 'Hub experiment start failed'
jq -e '.status == "running"' <<<"$START" >/dev/null || \
    harness_fail 'Hub did not start AB_BASE'

T0="$(date +%s)"
while :; do
    STATUS="$(flower_status 2>/dev/null || true)"
    if jq -e . <<<"$STATUS" >/dev/null 2>&1; then
        NEW_ID="$(jq -r '.model_run_id // empty' <<<"$STATUS")"
        [[ -n "$NEW_ID" ]] && ATTACK_RUN="$NEW_ID"
    fi
    if [[ -s "$MARKER" ]]; then
        break
    fi
    if ! is_running "$ROGUE_CONTAINER"; then
        docker logs "$ROGUE_CONTAINER" 2>&1 | tail -n 30 >&2 || true
        harness_fail 'Rogue probe terminated without a fit marker'
    fi
    if (( $(date +%s) - T0 >= TIMEOUT_S )); then
        fail "EP02 INCONCLUSIVE — no fit invocation observed within ${TIMEOUT_S}s"
        exit 70
    fi
    sleep 1
done

jq -e '.event == "fit_called" and .hospital == "A" and .org_id == "org://HospitalA"' \
    "$MARKER" >/dev/null || harness_fail 'Invalid duplicate-A fit evidence'
jq -e '.training.phase == "AB_BASE" and .training.guest_admission_decision_id == null and .training.guest_admission_run_id == null' \
    <<<"$STATUS" >/dev/null || harness_fail 'Unexpected training/admission context'

printf '\nEP02 execution-plane evidence\n'
jq . "$MARKER"
printf '%s\n' "$STATUS" | jq '{model_run_id, phase: .training.phase, round: .training.round}'
fail 'EP02 CONFIRMED — second unregistered Hospital A was selected for Flower fit'
exit 1
