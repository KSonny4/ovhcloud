#!/usr/bin/env bash
# Recreate a destroyed application workload, operator side (noninteractive).
#
# Resolves the recreate credential through OpenBao — explicit --db-password
# wins, else the escrowed per-workload entry is reused, else a fresh value
# is generated + escrowed — then runs the repo rollback on the target with
# the password delivered via stdin-piped environment (never argv, never
# disk on either end). The recreated credential stays known + escrowed, so
# consumers can re-point without a human relaying secrets.
#
# Usage:
#   [BAO_ADDR=...] bash scripts/recreate-workload.sh [--stamp STAMP] NAME
#     [--db-password PW] [--ssh-key PATH] [--host USER@HOST] [--resolve-only]
# --resolve-only proves the resolution path (logs the SOURCE only, never the
# value) and exits before any SSH; it exists for hermetic testing.
set -euo pipefail

stamp=''
name=''
db_password=''
ssh_key="${HOME}/.ssh/ovh_coolify_ed25519"
host='ubuntu@57.129.155.203'
resolve_only=0
bao_addr="${BAO_ADDR:-https://secrets.pkubelka.cz}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --stamp) stamp="$2"; shift 2 ;;
    --stamp=*) stamp="${1#--stamp=}"; shift ;;
    --db-password) db_password="$2"; shift 2 ;;
    --db-password=*) db_password="${1#--db-password=}"; shift ;;
    --ssh-key) ssh_key="$2"; shift 2 ;;
    --ssh-key=*) ssh_key="${1#--ssh-key=}"; shift ;;
    --host) host="$2"; shift 2 ;;
    --host=*) host="${1#--host=}"; shift ;;
    --resolve-only) resolve_only=1; shift ;;
    -h|--help) echo 'usage: recreate-workload.sh [--stamp STAMP] NAME [--db-password PW] [--ssh-key PATH] [--host USER@HOST] [--resolve-only]'; exit 0 ;;
    *) if [ -z "$name" ]; then name="$1"; shift; else echo "unknown argument: $1" >&2; exit 2; fi ;;
  esac
done
[ -n "$name" ] || { echo 'workload NAME required.' >&2; exit 2; }
case "$name" in *[!A-Za-z0-9_-]*) echo 'NAME must be [A-Za-z0-9_-] (maps to the escrow path).' >&2; exit 2 ;; esac
[ -f "$ssh_key" ] || { echo "SSH key not found: ${ssh_key}." >&2; exit 2; }
command -v bao >/dev/null 2>&1 || { echo 'bao CLI is required.' >&2; exit 2; }
command -v openssl >/dev/null 2>&1 || { echo 'openssl is required to generate passwords.' >&2; exit 2; }

# Escrow path is derived from the workload name (stable, auditable).
esc_path="secret/projects/ovhcloud/COOLIFY_WORKLOAD_$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]' | tr -c '[:upper:]0-9_' '_')"
export BAO_ADDR="$bao_addr"
if [ -n "$db_password" ]; then
  pw_source='explicit-flag (escrowed entry, if any, left untouched)'
elif existing="$(bao kv get -field=password "$esc_path" 2>/dev/null || true)"; [ -n "$existing" ]; then
  db_password="$existing"; existing=''
  pw_source="reused OpenBao ${esc_path}"
else
  db_password="$(openssl rand -base64 24)"
  stamp_for_escrow="${stamp:-latest}"
  bao kv put -mount=secret "projects/ovhcloud/COOLIFY_WORKLOAD_$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]' | tr -c '[:upper:]0-9_' '_')" "password=${db_password}" "stamp=${stamp_for_escrow}" "rotated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null \
    || { echo "password escrow to ${esc_path} failed (fail closed)." >&2; exit 2; }
  pw_source="generated + escrowed at ${esc_path}"
fi
log() { printf '%s\n' "$*"; }
log "recreate credential source: ${pw_source} (value never printed)."
if [ "$resolve_only" -eq 1 ]; then exit 0; fi

repo_root="$(cd "$(dirname "$0")" && pwd)"
for f in rollback-app-workloads.sh fetch-r2-env.sh; do
  scp -i "$ssh_key" -o BatchMode=yes -o ConnectTimeout=15 "$repo_root/$f" "${host}:/tmp/" >/dev/null \
    || { echo "staging ${f} failed." >&2; exit 2; }
done
stamp_part=''
if [ -n "$stamp" ]; then
  case "$stamp" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) stamp_part="--stamp $stamp" ;;
    *) echo 'stamp must look like 20260914T120000Z.' >&2; exit 2 ;; esac
fi
# Password travels on stdin into remote env (never argv: invisible to ps on
# both ends); sudo -E carries it into the fetch wrapper's process only.
# NAME is charset-restricted above and stamp format-validated: safe inline.
printf '%s' "$db_password" | ssh -i "$ssh_key" -o BatchMode=yes -o ConnectTimeout=20 "$host" \
  "read -rs APP_DB_PASSWORD; export APP_DB_PASSWORD; sudo -E bash /root/coolify-backup/fetch-r2-env.sh -- bash /tmp/rollback-app-workloads.sh ${stamp_part} --recreate $name"
rc=$?
db_password=''; unset APP_DB_PASSWORD 2>/dev/null || true
ssh -i "$ssh_key" -o BatchMode=yes -o ConnectTimeout=20 "$host" 'rm -f /tmp/rollback-app-workloads.sh /tmp/fetch-r2-env.sh' >/dev/null 2>&1 || true
if [ "$rc" -ne 0 ]; then echo 'remote recreate failed (fail closed; partial state left for inspection).' >&2; exit 2; fi
log "workload ${name} recreated; credential lives at ${esc_path} for consumer re-pointing."
