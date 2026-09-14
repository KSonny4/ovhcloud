#!/usr/bin/env bash
# Application-workload backup to Cloudflare R2 (databases + persistent volumes).
#
# Scope: the actual supported application scope beyond the Coolify control-plane
# database (which scripts/schedule-coolify-backup.sh covers). This script backs
# up, for every application workload on the host:
# - PostgreSQL databases in postgres-image containers (pg_dump custom format),
# - Docker named volumes (tar.gz snapshots),
# plus a JSON manifest of what was captured. Each goes to its R2 prefix with
# 14-day retention pruning.
#
# Excluded by default (infrastructure-owned, documented rationale):
# - coolify-db volume: covered authoritatively by pg_dump in schedule-coolify-backup.sh.
# - coolify-redis volume: ephemeral cache, safe to lose by design.
# Override with APP_VOLUME_EXCLUDE="vol1 vol2".
#
# Contract: runs as root ON the target host; R2 credentials from the root-only
# env file (0600) provisioned from OpenBao; never prints secrets; fail closed.
#
# Usage (on the host, as root):
#   bash scripts/backup-app-workloads.sh [--env-file PATH] [--dry-run]
set -euo pipefail

dry_run=0
env_file='/root/coolify-backup/r2.env'
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --env-file) env_file="$2"; shift 2 ;;
    --env-file=*) env_file="${1#--env-file=}"; shift ;;
    -h|--help) echo 'usage: backup-app-workloads.sh [--env-file PATH] [--dry-run]'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() { printf '%s\n' "$*"; }

if [ "$(id -u)" -ne 0 ] && [ "$dry_run" -eq 0 ]; then
  echo 'must run as root.' >&2
  exit 2
fi

exclude="${APP_VOLUME_EXCLUDE:-coolify-db coolify-redis}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"

if [ "$dry_run" -eq 1 ]; then
  log 'DRY-RUN: discover postgres containers (pg_dump each non-template DB to R2 app-databases/)'
  log 'DRY-RUN: snapshot each non-excluded Docker volume to R2 app-volumes/ (tar.gz sidecar)'
  log 'DRY-RUN: upload JSON manifest to R2 app-manifests/, prune all prefixes older than 14 days (fail closed)'
  exit 0
fi

# Credentials arrive via environment from fetch-r2-env.sh (memory-only); a
# legacy root-only env file is honored only as a fallback.
if [ -z "${R2_ACCESS_KEY_ID:-}" ] && [ -f "$env_file" ]; then
  # shellcheck source=/dev/null
  source "$env_file"
fi
for v in R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET; do
  if [ -z "${!v:-}" ]; then echo "missing ${v}: run through fetch-r2-env.sh (memory-only OpenBao pull)." >&2; exit 2; fi
done
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
command -v aws >/dev/null 2>&1 || { echo 'awscli is required.' >&2; exit 2; }
command -v docker >/dev/null 2>&1 || { echo 'docker is required.' >&2; exit 2; }

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
manifest_db='[]'
manifest_vol='[]'
FAILED=0

s3() { aws --endpoint-url "$R2_ENDPOINT" s3api "$@" >/dev/null; }

prune_prefix() {
  local prefix="$1" cutoff="$2" k day
  cutoff="$(date -u -d '14 days ago' +%Y%m%d)"
  for k in $(aws --endpoint-url "$R2_ENDPOINT" s3 ls "s3://${R2_BUCKET}/${prefix}" 2>/dev/null | awk '{print $4}'); do
    day="$(printf '%s' "$k" | grep -oE '[0-9]{8}T' | tr -d 'T' || true)"
    if [ -n "$day" ] && [ "$day" \< "$cutoff" ]; then
      s3 delete-object --bucket "$R2_BUCKET" --key "$k" && log "pruned ${k} (older than 14 days)"
    fi
  done
}

# --- application PostgreSQL databases ---
while IFS= read -r cname; do
  [ -n "$cname" ] || continue
  cenv="$(docker inspect "$cname" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null || true)"
  pguser="$(printf '%s' "$cenv" | grep -E '^POSTGRES_USER=' | cut -d= -f2- | head -n1 || true)"
  pguser="${pguser:-postgres}"
  # Password-authenticated containers need PGPASSWORD (taken from the
  # container's own env; never stored, only process environment).
  pgpass="$(printf '%s' "$cenv" | grep -E '^POSTGRES_PASSWORD=' | cut -d= -f2- | head -n1 || true)"
  db_exec=(docker exec)
  if [ -n "$pgpass" ]; then db_exec=(docker exec -e "PGPASSWORD=${pgpass}"); fi
  dbs="$("${db_exec[@]}" "$cname" psql -U "$pguser" -d postgres -tAc "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname NOT IN ('postgres');" 2>/dev/null || true)"
  for db in $dbs; do
    key="app-databases/${cname}-${db}-${stamp}.dump.gz"
    if "${db_exec[@]}" "$cname" pg_dump -Fc -U "$pguser" "$db" 2>/dev/null | gzip >"$workdir/db.dump.gz"; then
      s3 put-object --bucket "$R2_BUCKET" --key "$key" --body "$workdir/db.dump.gz"
      s3 head-object --bucket "$R2_BUCKET" --key "$key"
      manifest_db="$(printf '%s' "$manifest_db" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin) + [{"container": sys.argv[1], "database": sys.argv[2], "key": sys.argv[3]}]))' "$cname" "$db" "$key")"
      log "database backup ok: ${key}"
    else
      echo "FAILED to dump ${cname}/${db} (fail closed)." >&2
      FAILED=1
    fi
  done
done <<<"$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | grep -i postgres | awk '{print $1}' || true)"

# --- application volumes ---
while IFS= read -r vol; do
  [ -n "$vol" ] || continue
  skip=0
  for ex in $exclude; do
    if [ "$vol" = "$ex" ]; then skip=1; break; fi
  done
  if [ "$skip" -eq 1 ]; then log "volume skipped (infrastructure-owned): ${vol}"; continue; fi
  key="app-volumes/${vol}-${stamp}.tar.gz"
  if docker run --rm -v "${vol}:/data:ro" -v "${workdir}:/backup" alpine:3 tar czf "/backup/vol.tar.gz" -C /data . >/dev/null 2>&1; then
    s3 put-object --bucket "$R2_BUCKET" --key "$key" --body "$workdir/vol.tar.gz"
    s3 head-object --bucket "$R2_BUCKET" --key "$key"
    manifest_vol="$(printf '%s' "$manifest_vol" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin) + [{"volume": sys.argv[1], "key": sys.argv[2]}]))' "$vol" "$key")"
    log "volume backup ok: ${key}"
    rm -f "$workdir/vol.tar.gz"
  else
    echo "FAILED to snapshot volume ${vol} (fail closed)." >&2
    FAILED=1
  fi
done <<<"$(docker volume ls -q 2>/dev/null)"

# --- manifest + retention ---
manifest_key="app-manifests/${stamp}.json"
printf '{"stamp":"%s","databases":%s,"volumes":%s}\n' "$stamp" "$manifest_db" "$manifest_vol" >"$workdir/manifest.json"
s3 put-object --bucket "$R2_BUCKET" --key "$manifest_key" --body "$workdir/manifest.json"
prune_prefix 'app-databases/' 14
prune_prefix 'app-volumes/' 14
prune_prefix 'app-manifests/' 14

trap - EXIT
rm -rf "$workdir"
if [ "$FAILED" -ne 0 ]; then
  echo 'one or more workload backups failed (fail closed).' >&2
  exit 2
fi
log 'app-workload backup complete: databases + volumes + manifest in R2, 14-day retention.'
