#!/usr/bin/env bash
# Adopt fresh-edge resources into Terraform state (operator side).
#
# Pipeline: handoff JSON -> emit-fresh-imports.sh (generates main.tf +
# imports.tf, no hand authoring) -> terraform init (fresh backend key) ->
# plan (default; shows adoption) -> apply only with --apply AND an encrypted
# remote backend (backend.hcl). Backendless mode is validation/plan only;
# --apply without backend.hcl fails closed before any mutation.
# The run ends converged: a second plan shows no changes.
#
# Usage:
#   BAO_ADDR=... bash scripts/adopt-fresh-edge.sh --handoff PATH [--apply]
set -euo pipefail

apply=0
handoff=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) apply=1; shift ;;
    --handoff) handoff="$2"; shift 2 ;;
    --handoff=*) handoff="${1#--handoff=}"; shift ;;
    -h|--help) echo 'usage: adopt-fresh-edge.sh --handoff PATH [--apply]'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$handoff" ] && [ -f "$handoff" ] || { echo 'handoff JSON file required.' >&2; exit 2; }
command -v terraform >/dev/null 2>&1 || { echo 'terraform is required.' >&2; exit 2; }
command -v bao >/dev/null 2>&1 || { echo 'bao CLI is required.' >&2; exit 2; }
[ -n "${BAO_ADDR:-}" ] || { echo 'BAO_ADDR must be set.' >&2; exit 2; }

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
export CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-5eb3ea3a84b37564cfd8739f32ffb559}"
export CLOUDFLARE_ZONE_ID="${CLOUDFLARE_ZONE_ID:-0fcca39cc6516b8e23971bd717c0e9ca}"
# Work dir is overridable for hermetic testing; production default is the repo path.
fresh_dir="${TERRAFORM_FRESH_DIR:-$repo_root/infra/terraform-fresh}"
# Backendless mode is validation/plan ONLY: --apply without an encrypted
# remote backend would adopt provider state into a local file, contradicting
# the encrypted-state requirement. Fail closed before any mutation.
if [ "$apply" -eq 1 ] && [ ! -f "$fresh_dir/backend.hcl" ]; then
  echo "refusing --apply without an encrypted remote backend ($fresh_dir/backend.hcl missing); backendless mode is validation/plan only." >&2
  exit 2
fi
bash "$repo_root/scripts/emit-fresh-imports.sh" --handoff "$handoff" \
  --out-dir "$fresh_dir"

# Provider authorization from OpenBao (env-only, never files).
TF_VAR_cloudflare_api_token="$(bao kv get -field=ADMIN_CLOUDFLARE secret/projects/ovhcloud/ADMIN_CLOUDFLARE)"
TF_VAR_cloudflare_account_id="$CLOUDFLARE_ACCOUNT_ID"
TF_VAR_cloudflare_zone_id="$CLOUDFLARE_ZONE_ID"
TF_VAR_service_token_id="$(bao kv get -field=token_id secret/projects/ovhcloud/COOLIFY_ACCESS_SERVICE_TOKEN)"
export TF_VAR_cloudflare_api_token TF_VAR_cloudflare_account_id TF_VAR_cloudflare_zone_id TF_VAR_service_token_id
export TF_VAR_admin_emails='["ksonny4@gmail.com"]'
# S3-backend (R2 state) auth is memory-only env, never backend.hcl: the
# generated backend file carries names/URLs only by construction.
AWS_ACCESS_KEY_ID="$(bao kv get -field=access_key_id secret/projects/ovhcloud/COOLIFY_R2 2>/dev/null || true)"
AWS_SECRET_ACCESS_KEY="$(bao kv get -field=secret_access_key secret/projects/ovhcloud/COOLIFY_R2 2>/dev/null || true)"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
export AWS_DEFAULT_REGION
for v in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
  [ -n "${!v}" ] || { echo "OpenBao COOLIFY_R2 escrow missing for ${v} (fail closed)." >&2; exit 2; }
done
for v in TF_VAR_cloudflare_api_token TF_VAR_service_token_id; do
  [ -n "${!v}" ] || { echo "OpenBao escrow missing for ${v} (fail closed)."; exit 2; }
done

cd "$fresh_dir"
if [ -f backend.hcl ]; then
  terraform init -backend-config=backend.hcl -input=false
else
  echo 'backend.hcl missing (copy backend.hcl.example); running backend-less validation only.' >&2
  terraform init -backend=false -input=false
fi
if [ "$apply" -eq 1 ] && [ ! -f backend.hcl ]; then
  echo 'refusing --apply without an encrypted remote backend (backendless mode is validation/plan only).' >&2
  exit 2
fi
if [ "$apply" -eq 1 ]; then
  terraform apply -input=false -auto-approve
  terraform plan -input=false -detailed-exitcode
  rc=$?
  if [ "$rc" -eq 0 ]; then echo 'ADOPTED: second plan shows no changes.'; else exit "$rc"; fi
else
  terraform plan -input=false
fi
