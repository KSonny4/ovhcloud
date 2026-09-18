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
ssh_key="${HOME}/.ssh/ovh_nomad_ed25519"
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
esc_path="secret/projects/nomad/NOMAD_WORKLOAD_$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]' | tr -c '[:upper:]0-9_' '_')"
export BAO_ADDR="$bao_addr"
if [ -n "$db_password" ]; then
  pw_source='explicit-flag (escrowed entry, if any, left untouched)'
elif existing="$(bao kv get -field=password "$esc_path" 2>/dev/null || true)"; [ -n "$existing" ]; then
  db_password="$existing"; existing=''
  pw_source="reused OpenBao ${esc_path}"
else
  db_password="$(openssl rand -base64 24)"
  stamp_for_escrow="${stamp:-latest}"
  # password=- reads the value from stdin: never in argv (ps-visible),
  # never on disk; the other fields are non-secret metadata.
  printf '%s' "$db_password" | bao kv put -mount=secret "projects/nomad/NOMAD_WORKLOAD_$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]' | tr -c '[:upper:]0-9_' '_')" 'password=-' "stamp=${stamp_for_escrow}" "rotated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null \
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
# Secrets travel on stdin as one base64 blob into remote env (never argv:
# invisible to ps on both ends): the DB password plus every escrowed app
# secret for the stamp (resolved operator-side from OpenBao, so restore
# needs no human relay). sudo runs FIRST and the blob decodes in the root
# shell before fetch executes: sudo -E cannot carry arbitrary app-secret
# vars (the sudoers channel is a fixed allowlist; sudo-rs ignores -E
# otherwise), but stdin flows through NOPASSWD sudo untouched, so every
# blob var — present and future — survives with no channel update. NAME is
# charset-restricted above and stamp format-validated: safe inline.
if [ -z "$stamp" ]; then
  stamp="$(BAO_ADDR="$bao_addr" bash "$repo_root/fetch-app-secrets.sh" --resolve-latest-stamp 2>/dev/null || true)"
  [ -n "$stamp" ] || { echo 'no app manifest stamp found (fail closed).' >&2; exit 2; }
  stamp_part="--stamp $stamp"
fi
# Same shell-quoting discipline as the runner blob (qline): values travel
# base64-encoded on stdin, never argv.
qline() { printf 'export %s=%s\n' "$1" "$(printf '%s' "$2" | sed 's/[^A-Za-z0-9_.\/=+@:-]/\\&/g')"; }
secrets_blob="$({ BAO_ADDR="$bao_addr" bash "$repo_root/fetch-app-secrets.sh" --stamp "$stamp" --exports; qline APP_DB_PASSWORD "$db_password"; } | base64)"
printf '%s' "$secrets_blob" | ssh -i "$ssh_key" -o BatchMode=yes -o ConnectTimeout=20 "$host" \
  "sudo bash -c 'eval \"\$(base64 -d)\"; exec /root/host-backup/fetch-r2-env.sh -- bash /tmp/rollback-app-workloads.sh ${stamp_part} --recreate $name'"
rc=$?
db_password=''; secrets_blob=''; unset APP_DB_PASSWORD 2>/dev/null || true
ssh -i "$ssh_key" -o BatchMode=yes -o ConnectTimeout=20 "$host" 'rm -f /tmp/rollback-app-workloads.sh /tmp/fetch-r2-env.sh' >/dev/null 2>&1 || true
if [ "$rc" -ne 0 ]; then echo 'remote recreate failed (fail closed; partial state left for inspection).' >&2; exit 2; fi
log "workload ${name} recreated; credential lives at ${esc_path} for consumer re-pointing."
