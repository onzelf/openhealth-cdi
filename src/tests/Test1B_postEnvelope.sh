 #!/usr/bin/env bash
# Test_post_envelope.sh - Post-envelope verification using server /status + vault evidence
# Usage: ./Test_post_envelope.sh <envelope_id>

set -euo pipefail

ENVELOPE_ID="${1:-}"
if [[ -z "$ENVELOPE_ID" ]]; then
  echo "Usage: $0 <envelope_id>"
  exit 1
fi

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
pass() { printf "\033[32m✓\033[0m %s\n" "$*"; }
warn() { printf "\033[33m!\033[0m %s\n" "$*"; }
fail() { printf "\033[31m✗\033[0m %s\n" "$*"; exit 1; }
hr()   { printf "\n%s\n\n" "────────────────────────────────────────"; }

need_container() {
  local name="$1"
  docker ps -a --format '{{.Names}}' | grep -qx "$name" || fail "Missing container: $name"
}

is_running() {
  local name="$1"
  docker ps --format '{{.Names}}' | grep -qx "$name"
}

ensure_running() {
  local name="$1"
  if is_running "$name"; then
    return 0
  fi
  warn "$name is not running (may have exited). Restarting..."
  docker restart "$name" >/dev/null
  sleep 2
  is_running "$name" || fail "$name failed to start"
  pass "$name restarted"
}

log_has() {
  local name="$1"
  local pat="$2"
  if docker logs "$name" 2>&1 | grep  "$pat" > /dev/null; then
    return 0
  else
    return 1
  fi
}

# Call flower-server /status via hub (hub has curl in your environment)
flower_status() {
  docker exec -i fc-hub sh -lc 'curl -s --connect-timeout 2 --max-time 5 http://flower-server:8081/status' 2>/dev/null || true
}

wait_training_done() {
  local timeout_s="${1:-600}"   # 10 minutes
  local start_ts now out

  start_ts=$(date +%s)
  while true; do
    out="$(flower_status)"

    if [[ -z "$out" ]]; then
      echo "(!) No /status response yet"
    else
      echo "$out" | head -60

      # Success only when /status says done
      if echo "$out" | grep -qE '"training"\s*:\s*\{[^}]*"status"\s*:\s*"done"'; then
        return 0
      fi

      # Fail fast if /status reports error
      if echo "$out" | grep -qE '"training"\s*:\s*\{[^}]*"status"\s*:\s*"error"'; then
        return 1
      fi
    fi

    now=$(date +%s)
    if (( now - start_ts > timeout_s )); then
      return 1
    fi
    sleep 5
  done
}


bold "=== Post-Envelope Flow Test (Hub → bind → Flower run evidence) ==="
echo "Envelope ID: $ENVELOPE_ID"

# --- Step 0: Preflight ---
hr
bold "Step 0: Preflight container liveness"
need_container fc-hub
need_container flower-server
need_container flower-client-a
need_container flower-client-b

# Hub/server should be long-lived; clients may exit due to retry window.
ensure_running fc-hub
ensure_running flower-server
ensure_running flower-client-a
ensure_running flower-client-b

# --- Step 1: Hub received envelope event ---
hr
bold "Step 1: Verify Hub received envelope event"
if log_has fc-hub "$ENVELOPE_ID"; then
  pass "Hub received envelope event"
  docker logs fc-hub 2>&1 | grep "$ENVELOPE_ID" | tail -3 || true
else
  fail "Hub did not log the envelope. Check: docker logs fc-hub | tail -200"
fi

# --- Step 2: Hub attempted binding ---
hr
bold "Step 2: Verify Hub bound (or attempted to bind) flower_server"
if log_has fc-hub "Successfully bound flower_server"; then
  pass "Hub successfully bound flower_server"
elif log_has fc-hub "409|Conflict|already bound|Failed to bind backend flower_server"; then
  warn "Hub reports flower_server bind conflict (likely already bound from a previous run)."
  warn "If you intended a fresh envelope/training, reset with:"
  echo "  docker restart flower-server flower-client-a flower-client-b"
else
  fail "No binding outcome found in Hub logs. Check: docker logs fc-hub | tail -200"
fi

# --- Step 3: Flower server saw this envelope ---
hr
bold "Step 3: Verify flower-server references this envelope"
#if docker logs flower-server 2>&1 | grep  -F "$ENVELOPE_ID"; then
if log_has flower-server "$ENVELOPE_ID"; then
  pass "flower-server logs reference envelope_id"
  docker logs flower-server 2>&1 | grep "$ENVELOPE_ID" | tail -5 || true
else
  warn "flower-server logs do not mention the envelope id yet (may be log-format dependent)."
fi

# --- Step 4/5: Training progress via /status (authoritative) ---
hr
bold "Step 4: Wait for training completion (authoritative: /status)"
if wait_training_done 900; then
  pass "Training completed (per /status)"
else
  fail "Training did not complete (per /status)"
fi

# --- Step 6: Evidence check inside flower-server container (authoritative) ---
hr
bold "Step 5: Verify evidence in /vault/<envelope_id> (inside flower-server)"
if docker exec -i flower-server sh -lc "test -f /vault/${ENVELOPE_ID}/run.json"; then
  pass "Found /vault/${ENVELOPE_ID}/run.json"
  ls ../vfp-governance/verifier/vault/${ENVELOPE_ID}/*
  docker exec -i flower-server sh -lc "head -60 /vault/${ENVELOPE_ID}/run.json" || true
else
  warn "Missing /vault/${ENVELOPE_ID}/run.json inside flower-server"
  warn "Check mount + logs:"
  echo "  docker exec -it flower-server sh -lc 'ls -l /vault && find /vault -maxdepth 2 -name run.json -print'"
  fail "Evidence missing"
fi

hr
bold "=== Summary ==="
echo "Envelope: $ENVELOPE_ID"
echo ""
echo "Authoritative checks:"
echo "  docker exec -it fc-hub sh -lc 'curl -s http://flower-server:8081/status'"
echo "  docker exec -it flower-server sh -lc 'ls -l /vault/${ENVELOPE_ID}/run.json'"
echo ""
echo "If clients exited due to the ~10-minute retry window, restart them:"
echo "  docker restart flower-client-a flower-client-b"
echo ""
echo "If hub reports bind conflict (409), reset server + clients before a new envelope:"
echo "  docker restart flower-server flower-client-s flower-client-b"
