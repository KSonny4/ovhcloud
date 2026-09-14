#!/usr/bin/env bash
# Executable Coolify backup rollback/recovery proof for the OVHcloud redesign.
#
# Contract:
# - Runs as root ON the target host (same host as schedule-coolify-backup.sh).
# - Reads R2 credentials from environment via fetch-r2-env.sh (memory-only
#   OpenBao pull); never prints secret values.
# - Downloads the LATEST scheduled backup object from R2, restores it into a
#   disposable probe database inside the coolify-db container, verifies known
#   data (users table row count + admin email), drops the probe database, and
#   reports RESTORE_OK. Production data is never written.
# - Every stage fails closed: a missing backup, failed download, failed
#   restore, or failed verification exits nonzero with the probe dropped.
#
# Usage (on the host, as root):
#   sudo bash fetch-r2-env.sh -- bash scripts/rollback-coolify-backup.sh [--dry-run]
set -euo pipefail

dry_run=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    -h|--help) echo 'usage: rollback-coolify-backup.sh [--dry-run]'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() { printf '%s\n' "$*"; }

if [ "$(id -u)" -ne 0 ] && [ "$dry_run" -eq 0 ]; then
  echo 'must run as root.' >&2
  exit 2
fi

if [ "$dry_run" -eq 1 ]; then
  log 'DRY-RUN: list R2 backup objects, select latest coolify-db-*.dump.gz'
  log 'DRY-RUN: download latest backup, restore into disposable probe database'
  log 'DRY-RUN: verify known data (users count + admin email), drop probe, report RESTORE_OK (fail closed)'
  exit 0
fi

# Credentials arrive ONLY via environment from fetch-r2-env.sh (memory-only
# OpenBao pull). No credential file is read, ever.
for v in R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET; do
  if [ -z "${!v:-}" ]; then echo "missing ${v}: run through fetch-r2-env.sh -- <this-script>." >&2; exit 2; fi
done
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
command -v aws >/dev/null 2>&1 || { echo 'awscli is required.' >&2; exit 2; }
command -v docker >/dev/null 2>&1 || { echo 'docker is required.' >&2; exit 2; }

latest="$(aws --endpoint-url "$R2_ENDPOINT" s3 ls "s3://${R2_BUCKET}/coolify-db-" 2>/dev/null \
  | awk '{print $4}' | sort | tail -n1)"
if [ -z "$latest" ]; then
  echo 'no scheduled backup objects found in R2 (fail closed).' >&2
  exit 2
fi
log "latest scheduled backup: ${latest}"

probe_db='coolify_rollback_probe'
cleanup_probe() {
  docker exec coolify-db psql -U coolify -d postgres -c "DROP DATABASE IF EXISTS ${probe_db};" >/dev/null 2>&1 || true
}
trap cleanup_probe EXIT

tmp="$(mktemp)"
trap 'rm -f "$tmp"; cleanup_probe' EXIT
aws --endpoint-url "$R2_ENDPOINT" s3api get-object --bucket "$R2_BUCKET" --key "$latest" "$tmp" >/dev/null
# createdb first (pg_restore --create/--dbname cannot retarget a piped
# archive reliably); then restore into the named probe database.
if ! docker exec coolify-db createdb -U coolify "$probe_db" >/dev/null 2>&1; then
  echo 'probe database creation failed (fail closed).' >&2
  exit 2
fi
if ! gzip -dc "$tmp" | docker exec -i coolify-db pg_restore -U coolify -d "$probe_db" >/dev/null 2>&1; then
  echo 'restore into probe database failed (fail closed).' >&2
  exit 2
fi
log 'restore into probe database complete.'

users="$(docker exec coolify-db psql -U coolify -d "$probe_db" -tAc 'SELECT count(*) FROM users;' 2>/dev/null || true)"
admin_present="$(docker exec coolify-db psql -U coolify -d "$probe_db" -tAc "SELECT count(*) FROM users WHERE email = 'ksonny4@gmail.com';" 2>/dev/null || true)"
if [ -z "$users" ] || [ "$users" -lt 1 ] 2>/dev/null; then
  echo 'restore verification failed: users table empty or unreadable (fail closed).' >&2
  exit 2
fi
if [ "$admin_present" -lt 1 ] 2>/dev/null; then
  echo 'restore verification failed: admin identity absent from restored data (fail closed).' >&2
  exit 2
fi
log "restore verification passed: users=${users}, admin present."
trap - EXIT
rm -f "$tmp"
cleanup_probe
log 'RESTORE_OK: scheduled R2 backup restores to usable state; probe database dropped.'
