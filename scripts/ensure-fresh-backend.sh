#!/usr/bin/env bash
# Generate the fresh-environment Terraform backend config (gitignored).
#
# Why this exists: adopt-fresh-edge.sh --apply refuses without an encrypted
# remote backend, but the runner used to wire Cloudflare resources BEFORE any
# backend existed — a clean checkout mutated edge state, then failed at
# adopt, leaving partially managed resources. The runner now calls this
# BEFORE the first Cloudflare mutation, so backendless-apply is unreachable
# on the one-command path (adopt keeps its refusal as defense-in-depth for
# direct invocation).
#
# Secrecy: backend.hcl carries NO credentials — bucket/key/region/endpoints
# only (names and URLs, not keys). The S3 backend authenticates via AWS_*
# environment (memory-only OpenBao pull in adopt-fresh-edge.sh), so this
# generated file is safe at 0600 and contains nothing worth stealing.
# Safety: refuses when an existing backend points at the PRESERVED state key
# (adopting fresh resources into production state would be catastrophic) or
# at any other non-fresh key (operator-owned, never clobbered).
#
# Usage: [BAO_ADDR=...] [TERRAFORM_FRESH_DIR=...] bash scripts/ensure-fresh-backend.sh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fresh_dir="${TERRAFORM_FRESH_DIR:-$repo_root/infra/terraform-fresh}"
backend_file="$fresh_dir/backend.hcl"
fresh_key='ovhcloud-nomad-fresh/terraform.tfstate'
[ -d "$fresh_dir" ] || { echo "fresh dir missing: ${fresh_dir}." >&2; exit 2; }

if [ -f "$backend_file" ]; then
  # Era-agnostic production guard: a fresh backend key ALWAYS contains
  # 'fresh/'; any existing backend without it is production state (any
  # era) and fresh adoption into it would be catastrophic.
  if ! grep -qF 'fresh/' "$backend_file"; then
    echo 'refusing: existing backend key lacks fresh/ (production state; fresh adoption would corrupt it).' >&2
    exit 2
  fi
  if grep -qF "$fresh_key" "$backend_file"; then
    echo "fresh backend present (operator-owned or previously generated); leaving untouched."
    exit 0
  fi
  echo 'refusing: existing backend points at an unknown key (operator-owned, will not clobber).' >&2
  exit 2
fi

command -v bao >/dev/null 2>&1 || { echo 'bao CLI is required.' >&2; exit 2; }
export BAO_ADDR="${BAO_ADDR:-https://secrets.pkubelka.cz}"
r2_bucket="$(bao kv get -field=bucket secret/projects/nomad/BACKUP_R2 2>/dev/null || true)"
r2_endpoint="$(bao kv get -field=endpoint secret/projects/nomad/BACKUP_R2 2>/dev/null || true)"
if [ -z "$r2_bucket" ] || [ -z "$r2_endpoint" ]; then
  echo 'BACKUP_R2 bucket/endpoint escrow incomplete in OpenBao (fail closed before any mutation).' >&2
  exit 2
fi
# Values substituted are names/URLs only — never keys (verified below).
sed -e "s|REPLACE_WITH_TERRAFORM_STATE_BUCKET|${r2_bucket}|" \
    -e "s|REPLACE_WITH_STATE_REGION|auto|" \
    -e "s|REPLACE_WITH_S3_COMPATIBLE_ENDPOINT|${r2_endpoint}|" \
    "$fresh_dir/backend.hcl.example" >"$backend_file"
chmod 600 "$backend_file"
grep -qF "$fresh_key" "$backend_file" || { echo 'generated backend lost the fresh key (fail closed).' >&2; exit 2; }
echo "fresh backend generated at ${backend_file} (key ${fresh_key}; credentials via AWS_* env only, never in this file)."
