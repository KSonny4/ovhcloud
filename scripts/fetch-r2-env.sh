#!/usr/bin/env bash
# Runtime R2 credential delivery from OpenBao (memory-only).
#
# Replaces the static root-only r2.env file: the timer/rollback path execs
# through this wrapper, which reads a least-privilege OpenBao accessor token
# (0600, policy coolify-r2-reader: read-only on COOLIFY_R2), renews it,
# fetches the four R2 fields into process environment, and execs the given
# command. R2 keys never touch disk in any form — not even 0600.
#
# The accessor token file is the single secret at rest: revocable, renewable,
# audit-logged, and useless for anything but reading the R2 entry. Rotate via
# docs/secret-rotation.md (revoke accessor, mint replacement, swap file).
#
# Usage (on the host, as root):
#   bash scripts/fetch-r2-env.sh [--token-file PATH] -- <command> [args...]
set -euo pipefail

token_file='/root/coolify-backup/openbao-token'
while [ "$#" -gt 0 ]; do
  case "$1" in
    --token-file) token_file="$2"; shift 2 ;;
    --token-file=*) token_file="${1#--token-file=}"; shift ;;
    --) shift; break ;;
    -h|--help) echo 'usage: fetch-r2-env.sh [--token-file PATH] -- <command> [args...]'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ "$#" -gt 0 ] || { echo 'no command to exec.' >&2; exit 2; }
[ -f "$token_file" ] || { echo "OpenBao accessor token file not found: ${token_file}." >&2; exit 2; }
command -v bao >/dev/null 2>&1 || { echo 'bao CLI is required on the target.' >&2; exit 2; }
export BAO_ADDR="${BAO_ADDR:-https://secrets.pkubelka.cz}"
BAO_TOKEN="$(cat "$token_file")"
export BAO_TOKEN
[ -n "$BAO_TOKEN" ] || { echo 'accessor token file is empty.' >&2; exit 2; }

# Best-effort renewal (periodic token); a failed renewal is fatal only if the
# subsequent read also fails, so an expired token surfaces as a read error.
bao token renew-self >/dev/null 2>&1 || true
R2_ACCESS_KEY_ID="$(bao kv get -field=access_key_id secret/projects/ovhcloud/COOLIFY_R2 2>/dev/null || true)"
R2_SECRET_ACCESS_KEY="$(bao kv get -field=secret_access_key secret/projects/ovhcloud/COOLIFY_R2 2>/dev/null || true)"
R2_ENDPOINT="$(bao kv get -field=endpoint secret/projects/ovhcloud/COOLIFY_R2 2>/dev/null || true)"
R2_BUCKET="$(bao kv get -field=bucket secret/projects/ovhcloud/COOLIFY_R2 2>/dev/null || true)"
BAO_TOKEN=''
if [ -z "$R2_ACCESS_KEY_ID" ] || [ -z "$R2_SECRET_ACCESS_KEY" ] || [ -z "$R2_ENDPOINT" ] || [ -z "$R2_BUCKET" ]; then
  echo 'R2 credential fetch from OpenBao failed (token expired/revoked? see docs/secret-rotation.md).' >&2
  exit 2
fi
export R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
exec "$@"
