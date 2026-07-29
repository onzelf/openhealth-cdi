VAULT="../vfp-governance/verifier/vault"

for manifest in "$VAULT"/*/run.json; do
    [ -f "$manifest" ] || continue
    envelope_id="$(basename "$(dirname "$manifest")")"
    run_id="$(jq -r '.run_id // empty' "$manifest")"
    model="$(jq -r '.artifacts.model // empty' "$manifest")"

    printf '%-40s  %-28s  %s\n' \
        "$envelope_id" "$run_id" "$model"
done