#!/usr/bin/env bash
# Emit Terraform provider authorization as process-environment exports.
#
# The Terraform module takes provider authorization as variables. This loader
# is the noninteractive bridge: it retrieves every credential-bearing value
# through the existing OpenBao workflow plus read-only OVH CLI discovery, and
# emits them ONLY as `export` statements for eval. No credential file is ever
# written — there is no terraform.tfvars to create, format, shred, or leak
# (an earlier file-writing revision proved that any on-disk copy, however
# brief, ends up printed by tooling like `terraform fmt -diff`).
#
# Reads (OpenBao, by name only; values never printed):
#   ADMIN_CLOUDFLARE / COOLIFY_TUNNEL_SECRET.tunnel_secret / runner token file
#   COOLIFY_R2.{access_key_id,secret_access_key}
#   OVH_API.{application_key,application_secret,consumer_key,endpoint}
# The OVH CLI and the Terraform OVH provider both consume OVH_* natively, so
# discovery needs no credential file: the loader exports OVH_* first, then
# discovery runs against those exports. No local credential file is ever read.
# Emits to stdout: TF_VAR_* for every Terraform variable + AWS_* for the R2
# state backend. Everything else (progress) goes to stderr.
#
# Usage:
#   eval "$(BAO_ADDR=https://secrets.pkubelka.cz bash scripts/tf-env-from-openbao.sh)"
set -euo pipefail

dry_run=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    -h|--help) echo 'usage: tf-env-from-openbao.sh [--dry-run]'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '%s\n' "$*" >&2; }

if [ "$dry_run" -eq 1 ]; then
  log 'DRY-RUN: read ADMIN_CLOUDFLARE + tunnel_secret + runner token + R2 pair + OVH_API quad from OpenBao by name only'
  log 'DRY-RUN: export OVH_* from OpenBao, then discover VPS service name + IPv4 via read-only ovhcloud CLI (no local credential file)'
  log 'DRY-RUN: emit TF_VAR_* + AWS_* + OVH_* exports to stdout only (no file is ever written)'
  exit 0
fi

command -v bao >/dev/null 2>&1 || { echo 'bao CLI is required.' >&2; exit 2; }
command -v ovhcloud >/dev/null 2>&1 || { echo 'ovhcloud CLI is required for VPS discovery.' >&2; exit 2; }
bao_addr="${BAO_ADDR:-https://secrets.pkubelka.cz}"
export BAO_ADDR="$bao_addr"
bao_token_file="${BAO_TOKEN_FILE:-$HOME/.vault-token}"
if [ ! -f "$bao_token_file" ]; then
  echo "OpenBao runner token file not found: ${bao_token_file}." >&2
  exit 2
fi

log 'retrieving provider authorization from OpenBao (names only)...'
cf_token="$(bao kv get -field=ADMIN_CLOUDFLARE secret/projects/ovhcloud/ADMIN_CLOUDFLARE)"
tunnel_secret="$(bao kv get -field=tunnel_secret secret/projects/ovhcloud/COOLIFY_TUNNEL_SECRET)"
r2_ak="$(bao kv get -field=access_key_id secret/projects/ovhcloud/COOLIFY_R2)"
r2_sk="$(bao kv get -field=secret_access_key secret/projects/ovhcloud/COOLIFY_R2)"
ovh_ak="$(bao kv get -field=application_key secret/projects/ovhcloud/OVH_API)"
ovh_as="$(bao kv get -field=application_secret secret/projects/ovhcloud/OVH_API)"
ovh_ck="$(bao kv get -field=consumer_key secret/projects/ovhcloud/OVH_API)"
ovh_ep="$(bao kv get -field=endpoint secret/projects/ovhcloud/OVH_API)"
for v in cf_token tunnel_secret r2_ak r2_sk ovh_ak ovh_as ovh_ck ovh_ep; do
  if [ -z "${!v}" ]; then echo "OpenBao escrow missing for ${v}; refusing to continue." >&2; exit 2; fi
done

log 'discovering preserved VPS identity via read-only OVH CLI (OVH_* from OpenBao, no file)...'
export OVH_ENDPOINT="$ovh_ep" OVH_APPLICATION_KEY="$ovh_ak" OVH_APPLICATION_SECRET="$ovh_as" OVH_CONSUMER_KEY="$ovh_ck"
service_name="$(ovhcloud vps list --output json 2>/dev/null | jq -r '.[0].displayName // empty')"
if [ -z "$service_name" ]; then echo 'OVH VPS discovery returned no service.' >&2; exit 2; fi
ipv4="$(ovhcloud vps ip list "$service_name" --output json 2>/dev/null | jq -r '.[] | select(.version == "v4") | .ipAddress // empty' | head -n1)"
if [ -z "$ipv4" ]; then echo 'OVH IP discovery returned no IPv4.' >&2; exit 2; fi
log "discovered service ${service_name} (${ipv4}); emitting exports only, never files."

# Single-quote every value so eval reproduces exact bytes (no file involved).
printf 'export TF_VAR_cloudflare_api_token=%s\n' "$(printf '%s' "$cf_token" | sed "s/'/'\\\\''/g; s/^/'/; s/$/'/")"
printf 'export TF_VAR_cloudflare_account_id=%s\n' "'5eb3ea3a84b37564cfd8739f32ffb559'"
printf 'export TF_VAR_cloudflare_tunnel_secret=%s\n' "$(printf '%s' "$tunnel_secret" | sed "s/'/'\\\\''/g; s/^/'/; s/$/'/")"
# No TF_VAR_openbao_* exports: escrow lives outside Terraform by design.
printf 'export TF_VAR_domain=%s\n' "'pkubelka.cz'"
printf 'export TF_VAR_ovh_ipv4=%s\n' "'$ipv4'"
printf 'export TF_VAR_ovh_service_name=%s\n' "'$service_name'"
printf 'export TF_VAR_admin_emails=%s\n' "'[\"ksonny4@gmail.com\"]'"
printf 'export TF_VAR_r2_bucket_name=%s\n' "'ovh-coolify-backups'"
printf 'export TF_VAR_manage_application_wildcard=%s\n' "'false'"
printf 'export TF_VAR_access_service_token_name=%s\n' "'ovh-coolify-machine-verification'"
printf 'export TF_VAR_access_service_token_duration=%s\n' "'8760h'"
printf 'export TF_VAR_provision_ovh_vps=%s\n' "'false'"
printf 'export TF_VAR_manage_existing_vps=%s\n' "'true'"
log 'OpenBao address: %s (used for reads only, never a Terraform input).' "$bao_addr"
q() { printf '%s' "$1" | sed "s/'/'\\\\''/g; s/^/'/; s/$/'/"; }
# OVH provider + CLI authorization (env-native; no file).
printf 'export OVH_ENDPOINT=%s\n' "$(q "$ovh_ep")"
printf 'export OVH_APPLICATION_KEY=%s\n' "$(q "$ovh_ak")"
printf 'export OVH_APPLICATION_SECRET=%s\n' "$(q "$ovh_as")"
printf 'export OVH_CONSUMER_KEY=%s\n' "$(q "$ovh_ck")"
printf 'export AWS_ACCESS_KEY_ID=%s\n' "$(printf '%s' "$r2_ak" | sed "s/'/'\\\\''/g; s/^/'/; s/$/'/")"
printf 'export AWS_SECRET_ACCESS_KEY=%s\n' "$(printf '%s' "$r2_sk" | sed "s/'/'\\\\''/g; s/^/'/; s/$/'/")"
log 'exports emitted (eval this output); no credential file was written.'
