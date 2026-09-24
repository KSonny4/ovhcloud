#!/usr/bin/env bash
# Deliver the R2 and Neon backup credentials from OpenBao memory-only.
set -euo pipefail

token_file='/root/host-backup/openbao-token'
while [ "$#" -gt 0 ]; do
  case "$1" in
    --token-file) token_file="$2"; shift 2 ;;
    --token-file=*) token_file="${1#--token-file=}"; shift ;;
    --) shift; break ;;
    -h|--help) echo 'usage: fetch-openbao-db-env.sh [--token-file PATH] -- <command> [args...]'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ "$#" -gt 0 ] || { echo 'no command to exec.' >&2; exit 2; }
[ -f "$token_file" ] || { echo 'OpenBao accessor token file is missing.' >&2; exit 2; }
command -v bao >/dev/null 2>&1 || { echo 'bao CLI is required on the target.' >&2; exit 2; }
export BAO_ADDR="${BAO_ADDR:-https://secrets.pkubelka.cz}"
BAO_TOKEN="$(cat "$token_file")"
export BAO_TOKEN
[ -n "$BAO_TOKEN" ] || { echo 'OpenBao accessor token file is empty.' >&2; exit 2; }
bao token renew-self >/dev/null 2>&1 || true

read_field() {
  bao kv get -field="$2" "secret/projects/nomad/$1" 2>/dev/null || true
}

R2_ACCESS_KEY_ID="$(read_field BACKUP_R2 access_key_id)"
R2_SECRET_ACCESS_KEY="$(read_field BACKUP_R2 secret_access_key)"
R2_ENDPOINT="$(read_field BACKUP_R2 endpoint)"
R2_BUCKET="$(read_field BACKUP_R2 bucket)"
NEON_API_KEY="$(read_field OPENBAO_NEON_BACKUP api_key)"
NEON_PROJECT_ID="$(read_field OPENBAO_NEON_BACKUP project_id)"
NEON_PARENT_BRANCH_ID="$(read_field OPENBAO_NEON_BACKUP parent_branch_id)"
NEON_DATABASE="$(read_field OPENBAO_NEON_BACKUP database)"
NEON_USERNAME="$(read_field OPENBAO_NEON_BACKUP username)"
NEON_PASSWORD="$(read_field OPENBAO_NEON_BACKUP password)"
BAO_TOKEN=''

if [ -z "$R2_ACCESS_KEY_ID" ] || [ -z "$R2_SECRET_ACCESS_KEY" ] || [ -z "$R2_ENDPOINT" ] || [ -z "$R2_BUCKET" ]; then
  echo 'R2 credential fetch failed (token expired/revoked or backup-r2-reader policy lacks BACKUP_R2).' >&2
  exit 2
fi
if [ -z "$NEON_API_KEY" ] || [ -z "$NEON_PROJECT_ID" ] || [ -z "$NEON_PARENT_BRANCH_ID" ] || [ -z "$NEON_DATABASE" ] || [ -z "$NEON_USERNAME" ] || [ -z "$NEON_PASSWORD" ]; then
  echo 'Neon backup credential fetch failed (OPENBAO_NEON_BACKUP entry/policy is not provisioned).' >&2
  exit 2
fi

export R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
export NEON_API_KEY NEON_PROJECT_ID NEON_PARENT_BRANCH_ID NEON_DATABASE NEON_USERNAME NEON_PASSWORD
exec "$@"
