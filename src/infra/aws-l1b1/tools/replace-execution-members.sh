#!/usr/bin/env bash
# L1-B2, on the governance host: register the hospitals' new Flower execution keys (public halves
# made by make-execution-key.py in each hospital's own account) in place of the host-made ones.
#
#   bash replace-execution-members.sh ~/execution-public-a.json ~/execution-public-b.json ~/execution-public-c.json
#
# The issuers have no replace endpoint (a second registration of a sub is refused with 409), so for
# each key this script, in order:
#   0. checks the issuer answers with the admin certificate (nothing changes if it doesn't);
#   1. backs up the issuer's registry file inside its volume (<file>.bak-<time>-<sub>, one per entry);
#   2. removes only that one entry (sub flower-execution, or flower-execution-guest-HospitalC);
#   3. registers the new public key through the issuer's own API with the organisation's admin
#      certificate, exactly as src/tools/bootstrap_members.sh does;
#   4. reads the members list back and checks the new key is the one registered.
# If the registration fails, the registry file is restored from that backup before the script stops.
# A rerun with the same files is safe. The edit is not taken under the issuer's own registry lock, so
# don't run it while anything else registers members on that issuer.
# Audrey, Bob, Charlie and every other entry are untouched. Run from ~/openhealth-cdi.
# Afterwards, select the envelope again so the hub binds the new keys to Flower.
set -euo pipefail

REPO="${REPO:-${HOME}/openhealth-cdi}"
CERTS="${REPO}/src/vfp-governance/verifier/certs"
ISSUER_IP="${ISSUER_IP:-127.0.0.1}"
ISSUER_PORT="${ISSUER_PORT:-9443}"
pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
[[ $# -ge 1 ]] || fail "usage: $0 <execution-public-x.json>..."
for c in curl jq docker; do command -v "$c" >/dev/null || fail "missing $c"; done

issuer_for() {  # org -> container, host name, admin cert prefix
  case "$1" in
    org://HospitalA) echo "issuer-hospitala issuer-hospitala.local HospitalA-admin" ;;
    org://HospitalB) echo "issuer-hospitalb issuer-hospitalb.local HospitalB-admin" ;;
    *) fail "unexpected organisation $1" ;;
  esac
}

for file in "$@"; do
  [[ -s "${file}" ]] || fail "missing ${file}"
  org="$(jq -er .org_id "${file}")"; sub="$(jq -er .sub "${file}")"
  pub="$(jq -er .pub_b64 "${file}")"; jkt="$(jq -er .jkt "${file}")"
  case "${sub}" in flower-execution|flower-execution-guest-HospitalC) ;; *) fail "refusing to touch sub ${sub}" ;; esac
  read -r container host cert <<<"$(issuer_for "${org}")"
  echo "== ${sub} at ${org} (${container})"

  # 0. nothing is removed unless the issuer answers with this certificate
  curl -fsS --cacert "${CERTS}/ca.crt" --cert "${CERTS}/${cert}.crt" --key "${CERTS}/${cert}.key" \
    --resolve "${host}:${ISSUER_PORT}:${ISSUER_IP}" -o /dev/null "https://${host}:${ISSUER_PORT}/members" \
    || fail "${host}:${ISSUER_PORT} does not answer with ${cert}; nothing was changed"

  # 1-2. back up the registry file and remove only this entry (the issuer reads the file on each request)
  out="$(docker exec -i "${container}" python3 - "${sub}" <<'PY'
import glob, json, os, shutil, sys, time
sub = sys.argv[1]
files = glob.glob(os.path.join(os.environ.get("REGISTRY_DIR", "/vault/registry"), "*.members.json"))
assert len(files) == 1, files
path = files[0]
reg = json.load(open(path))
backup = f"{path}.bak-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}-{sub}"  # one backup per replaced entry
shutil.copy2(path, backup)
removed = reg.pop(sub, None) is not None
tmp = path + ".tmp"
with open(tmp, "w") as handle:
    json.dump(reg, handle, indent=2, sort_keys=True)
os.replace(tmp, path)
print(f"backup {os.path.basename(backup)}; removed old {sub}: {removed}; {len(reg)} other entries kept")
print(f"REGISTRY={path}")
print(f"BACKUP={backup}")
PY
)"
  echo "${out}" | grep -v -E '^(REGISTRY|BACKUP)=' || true
  registry="$(echo "${out}" | sed -n 's/^REGISTRY=//p')"; backup="$(echo "${out}" | sed -n 's/^BACKUP=//p')"
  [[ -n "${registry}" && -n "${backup}" ]] || fail "${sub}: no backup recorded; check ${container} by hand"

  # 3. register the new public key with the organisation's admin certificate
  body="$(jq -nc --arg org "${org}" --arg sub "${sub}" --arg pub "${pub}" --arg jkt "${jkt}" \
    '{org_id: $org, member_id: $sub, sub: $sub, pub_b64: $pub, jkt: $jkt}')"
  status="$(curl -sS --cacert "${CERTS}/ca.crt" --cert "${CERTS}/${cert}.crt" --key "${CERTS}/${cert}.key" \
    --resolve "${host}:${ISSUER_PORT}:${ISSUER_IP}" -o /dev/null -w '%{http_code}' \
    -X POST -H 'content-type: application/json' -d "${body}" "https://${host}:${ISSUER_PORT}/members/register" || true)"
  if [[ "${status}" != "200" ]]; then
    docker exec "${container}" cp "${backup}" "${registry}" \
      && fail "registration of ${sub} returned HTTP ${status:-none}; registry restored from ${backup}" \
      || fail "registration of ${sub} returned HTTP ${status:-none} and the restore failed: copy ${backup} over ${registry} in ${container}"
  fi

  # 4. read it back
  got="$(curl -sS --cacert "${CERTS}/ca.crt" --cert "${CERTS}/${cert}.crt" --key "${CERTS}/${cert}.key" \
    --resolve "${host}:${ISSUER_PORT}:${ISSUER_IP}" "https://${host}:${ISSUER_PORT}/members" \
    | jq -r --arg sub "${sub}" '.members[] | select(.sub == $sub) | "\(.pub_b64) \(.jkt)"' || true)"
  [[ "${got}" == "${pub} ${jkt}" ]] || fail "${sub}: the registry does not hold the new key"
  pass "${sub} at ${org} now holds the key made in Hospital $(jq -r .hospital "${file}")'s account"
done
