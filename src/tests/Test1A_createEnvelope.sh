#!/usr/bin/env bash
# Test1A_createEnvelope.sh - Complete envelope creation flow

set -euo pipefail

#LAN="${LAN:-192.168.1.25}"
LAN="verifier.local"
CRT="../vfp-governance/verifier/certs/hub.crt"
KEY="../vfp-governance/verifier/certs/hub.key"

bold() { printf "\033[1m%s\033[0m\n" "$*"; }

bold "=== Step 1: Initialize Bind ==="

PAYLOAD='{}'

BIND_ID=$(curl -sk --cert "$CRT" --key "$KEY" \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD" \
  "https://${LAN}:8443/beta/bind/init" | jq -r .bind_id)

echo "Bind ID: $BIND_ID"
echo ""

bold "=== Step 2: Get codes from phones ==="
echo "Now run /verify-start on both physical phones"
echo "Enter the 6-digit codes displayed:"
read -rp "CODE_A (HospitalA): " CODE_A
read -rp "CODE_B (HospitalB): " CODE_B

bold "=== Step 3: Claim sessions ==="
SID_A=$(curl -sk --cert "$CRT" --key "$KEY" \
  "https://${LAN}:8443/session/claim?code=${CODE_A}" | jq -r .session_id)
SID_B=$(curl -sk --cert "$CRT" --key "$KEY" \
  "https://${LAN}:8443/session/claim?code=${CODE_B}" | jq -r .session_id)

echo "Session A: $SID_A"
echo "Session B: $SID_B"
echo ""

bold "=== Step 4: First approval (HospitalA) ==="
curl -sk --cert "$CRT" --key "$KEY" \
  -H 'Content-Type: application/json' \
  -d "{\"bind_id\":\"${BIND_ID}\",\"session_id\":\"${SID_A}\"}" \
  "https://${LAN}:8443/beta/bind/approve" | jq .

echo ""
bold "=== Step 5: Second approval (HospitalB - reaches quorum) ==="
RESULT=$(curl -sk --cert "$CRT" --key "$KEY" \
  -H 'Content-Type: application/json' \
  -d "{\"bind_id\":\"${BIND_ID}\",\"session_id\":\"${SID_B}\"}" \
  "https://${LAN}:8443/beta/bind/approve")

echo "$RESULT" | jq .

ENVELOPE_ID=$(echo "$RESULT" | jq -r '.envelope_id // .envelope.envelope_id')
echo ""
echo "✓ Envelope created: $ENVELOPE_ID"
echo ""
echo "Run post-envelope test:"
echo "./Test1B_postEnvelope.sh $ENVELOPE_ID"
