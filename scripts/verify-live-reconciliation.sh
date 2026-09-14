#!/usr/bin/env bash
# Verify live Terraform reconciliation (operator side, read-only except init).
#
# Proves, against the REAL encrypted backend, without touching the live
# working dir (disposable copy): which resources live in state (imported
# addresses), that the preserved VPS is managed + destroy-protected, and
# that the plan is empty. Writes redacted machine-readable evidence to
# docs/live-reconciliation.json (addresses and counts only — never values).
#
# Usage:
#   BAO_ADDR=https://secrets.pkubelka.cz bash scripts/verify-live-reconciliation.sh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
log() { printf '%s\n' "$*"; }

[ -n "${BAO_ADDR:-}" ] || { echo 'BAO_ADDR must be set.' >&2; exit 2; }
command -v terraform >/dev/null 2>&1 || { echo 'terraform is required.' >&2; exit 2; }
[ -f "$repo_root/infra/terraform/backend.hcl" ] || { echo 'backend.hcl missing (copy backend.hcl.example).' >&2; exit 2; }

# Provider authorization from OpenBao (env-only, never files).
# Two-step eval: a bare eval "$(...)" would mask a loader failure (eval
# returns its own status), falling back to ambient credentials downstream.
loader_out="$(BAO_ADDR="$BAO_ADDR" bash "$repo_root/scripts/tf-env-from-openbao.sh")" || { echo 'OpenBao loader failed.' >&2; exit 2; }
eval "$loader_out"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$repo_root"/infra/terraform/*.tf "$repo_root"/infra/terraform/backend.hcl "$work/"
cd "$work"
terraform init -backend-config=backend.hcl -input=false >/dev/null || { echo 'backend init failed.' >&2; exit 2; }

state_list="$(terraform state list 2>/dev/null || true)"
[ -n "$state_list" ] || { echo 'empty state (fail closed).' >&2; exit 2; }

# Preserved-VPS protection: managed resource + prevent_destroy in config.
grep -q 'resource "ovh_vps" "preserved"' "$repo_root/infra/terraform/main.tf" || { echo 'preserved VPS resource missing from config.' >&2; exit 2; }
grep -q 'prevent_destroy = true' "$repo_root/infra/terraform/main.tf" || { echo 'prevent_destroy missing from config.' >&2; exit 2; }
printf '%s' "$state_list" | grep -q '^ovh_vps\.preserved' || { echo 'preserved VPS not in live state.' >&2; exit 2; }

# Expected imported families (addresses only, IDs never printed).
families='cloudflare_zero_trust_tunnel_cloudflared
cloudflare_zero_trust_tunnel_cloudflared_config
cloudflare_dns_record
cloudflare_zero_trust_access_application
cloudflare_zero_trust_access_identity_provider
cloudflare_zero_trust_access_service_token
cloudflare_r2_bucket
ovh_vps.preserved'
missing=''
while IFS= read -r fam; do
  [ -n "$fam" ] || continue
  printf '%s' "$state_list" | grep -q "^${fam}" || missing="${missing} ${fam}"
done <<<"$families"
[ -z "$missing" ] || { echo "live state misses families:${missing}" >&2; exit 2; }

# Zero-change plan (default refresh: detects drift, prints no values when empty).
set +e
plan_out="$(terraform plan -input=false -detailed-exitcode 2>&1)"
plan_rc=$?
set -e
if [ "$plan_rc" -ne 0 ]; then
  printf '%s\n' "$plan_out" | grep -aE 'to add|to change|to destroy' | head -5 >&2
  echo 'live plan is not empty (fail closed).' >&2
  exit 2
fi

# Redacted machine-readable evidence (addresses + counts only).
stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
python3 - >"$repo_root/docs/live-reconciliation.json" <<PYEOF
import json
addrs = """$state_list""".split()
print(json.dumps({
  "generated_utc": "$stamp",
  "backend": "s3 (R2, encrypted at rest, locked)",
  "plan": "empty (detailed-exitcode 0, default refresh)",
  "preserved_vps_managed": True,
  "prevent_destroy": True,
  "resource_count": len(addrs),
  "state_addresses": sorted(addrs),
}, indent=2))
PYEOF
trap - EXIT
rm -rf "$work"
# Scrub secret-bearing env from this shell before exiting.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY TF_VAR_cloudflare_api_token TF_VAR_service_token_id CLOUDFLARE_API_TOKEN OVH_ENDPOINT OVH_APPLICATION_KEY OVH_APPLICATION_SECRET OVH_CONSUMER_KEY R2_ENDPOINT R2_BUCKET TF_VAR_admin_emails 2>/dev/null || true
log "live reconciliation verified: $(printf '%s' "$state_list" | wc -l | tr -d ' ') resources in state, plan empty; evidence at docs/live-reconciliation.json."
