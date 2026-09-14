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
# Contract: runs as root ON the target host; R2 credentials ONLY from
# environment via fetch-r2-env.sh (memory-only OpenBao pull); never prints
# secrets; fail closed.
#
# Usage (on the host, as root):
#   bash scripts/backup-app-workloads.sh [--dry-run]
set -euo pipefail

dry_run=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    -h|--help) echo 'usage: backup-app-workloads.sh [--dry-run]'; exit 0 ;;
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
  log 'DRY-RUN: enforce workload coverage contract (fail closed on unbackupable mounts/DBs)'
  log 'DRY-RUN: discover postgres containers (pg_dump each non-template DB to R2 app-databases/, record tables+rows)'
  log 'DRY-RUN: snapshot each non-excluded Docker volume to R2 app-volumes/ (record files+bytes)'
  log 'DRY-RUN: snapshot APP_BIND_PATHS host dirs to R2 app-binds/'
  log 'DRY-RUN: upload JSON manifest to R2 app-manifests/, prune all prefixes older than 14 days (fail closed)'
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

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
manifest_db='[]'
manifest_vol='[]'
manifest_binds='[]'
FAILED=0

# --- workload coverage contract (fail closed on gaps) ---
# Covered: PostgreSQL databases (native dump), Docker named volumes
# (snapshots, except documented infra exclusions), and host directories
# listed in APP_BIND_PATHS (tar snapshots, e.g. SQLite directories).
# Platform-owned coolify* containers are skipped by design (control-plane DB
# covered authoritatively by schedule-coolify-backup.sh; redis is ephemeral
# cache; proxy/sentinel/realtime are stateless). Anything else stateful that
# this script cannot back up fails the run with an explicit gap list.
system_binds='/etc/hostname /etc/hosts /etc/resolv.conf /etc/resolve.conf /run/docker.sock'
gaps=''
for cname in $(docker ps --format '{{.Names}}' 2>/dev/null || true); do
  case "$cname" in coolify*) continue ;; esac
  [ -n "$cname" ] || continue
  image="$(docker inspect "$cname" --format '{{.Config.Image}}' 2>/dev/null || true)"
  case "$image" in
    *mysql*|*mariadb*|*mongo*|*redis*|*memcached*|*cassandra*|*couchdb*|*elasticsearch*|*clickhouse*)
      gaps="${gaps} container ${cname} image ${image}: no native dumper (only postgres supported);" ;;
  esac
  mounts="$(docker inspect "$cname" --format '{{range .Mounts}}{{println .Type .Source}}{{end}}' 2>/dev/null || true)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    mtype="${line%% *}"; src="${line#* }"
    [ "$mtype" = 'bind' ] || continue
    sys=0; for s in $system_binds; do [ "$src" = "$s" ] && sys=1; done
    [ "$sys" -eq 1 ] && continue
    declared=0; for b in ${APP_BIND_PATHS:-}; do [ "$src" = "$b" ] && declared=1; done
    if [ "$declared" -eq 0 ]; then
      gaps="${gaps} container ${cname} bind ${src}: undeclared (add to APP_BIND_PATHS or exclude deliberately);"
    fi
  done <<<"$mounts"
done
if [ -n "$gaps" ]; then
  echo "WORKLOAD COVERAGE GAP (fail closed): ${gaps}" >&2
  printf '{"stamp":"%s","databases":[],"volumes":[],"binds":[],"gaps":%s}\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$(printf '%s' "$gaps" | python3 -c 'import json,sys; print(json.dumps([g for g in sys.stdin.read().split(";") if g]))')" >"$workdir/gaps.json"
  s3 put-object --bucket "$R2_BUCKET" --key "app-manifests/gaps-$(date -u +%Y%m%dT%H%M%SZ).json" --body "$workdir/gaps.json" || true
  exit 2
fi
log 'workload coverage ok: no unbackupable stateful mounts or databases detected.'

s3() { aws --endpoint-url "$R2_ENDPOINT" s3api "$@" >/dev/null; }

# NOTE: s3 ls returns bare filenames; delete-object needs the FULL key
# (prefix + name). Deleting a bare name succeeds vacuously (S3 returns
# success for nonexistent keys) while deleting nothing — a silent retention
# failure. Always reattach the prefix.
prune_prefix() {
  local prefix="$1" cutoff="$2" k day
  cutoff="$(date -u -d '14 days ago' +%Y%m%d)"
  for k in $(aws --endpoint-url "$R2_ENDPOINT" s3 ls "s3://${R2_BUCKET}/${prefix}" 2>/dev/null | awk '{print $4}'); do
    day="$(printf '%s' "$k" | grep -oE '[0-9]{8}T' | tr -d 'T' || true)"
    if [ -n "$day" ] && [ "$day" \< "$cutoff" ]; then
      s3 delete-object --bucket "$R2_BUCKET" --key "${prefix}${k}" && log "pruned ${prefix}${k} (older than 14 days)"
    fi
  done
}

# --- application PostgreSQL databases ---
while IFS= read -r cname; do
  [ -n "$cname" ] || continue
  image="$(docker inspect "$cname" --format '{{.Config.Image}}' 2>/dev/null || true)"
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
    precheck="$("${db_exec[@]}" "$cname" psql -U "$pguser" -d "$db" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null || echo 0)"
    if [ "${precheck:-0}" -eq 0 ]; then
      log "database skipped (empty, no user tables): ${cname}/${db}"
      continue
    fi
    if "${db_exec[@]}" "$cname" pg_dump -Fc -U "$pguser" "$db" 2>/dev/null | gzip >"$workdir/db.dump.gz"; then
      s3 put-object --bucket "$R2_BUCKET" --key "$key" --body "$workdir/db.dump.gz"
      s3 head-object --bucket "$R2_BUCKET" --key "$key"
      # Verifiable counts for restore: tables + total rows (in-service
      # restores must prove data parity, not just readability).
      counts="$("${db_exec[@]}" "$cname" psql -U "$pguser" -d "$db" -tAc "SELECT (SELECT count(*) FROM information_schema.tables WHERE table_schema='public'), coalesce((SELECT sum(n_live_tup)::int FROM pg_stat_user_tables),0);" 2>/dev/null || echo '0|0')"
      tables="${counts%%|*}"; rows="${counts##*|}"
      manifest_db="$(printf '%s' "$manifest_db" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin) + [{"container": sys.argv[1], "image": sys.argv[6], "user": sys.argv[7], "database": sys.argv[2], "key": sys.argv[3], "tables": int(sys.argv[4]), "rows": int(sys.argv[5])}]))' "$cname" "$db" "$key" "${tables:-0}" "${rows:-0}" "$image" "${pguser}")"
      log "database backup ok: ${key} (tables=${tables:-0}, rows=${rows:-0})"
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
    volstat="$(docker run --rm -v "${vol}:/data:ro" alpine:3 sh -c 'find /data -type f | wc -l; du -sb /data | cut -f1' 2>/dev/null | awk 'NR==1{f=$1} NR==2{b=$1} END{print f"|"b}' || echo '0|0')"
    vfiles="${volstat%%|*}"; vbytes="${volstat##*|}"
    manifest_vol="$(printf '%s' "$manifest_vol" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin) + [{"volume": sys.argv[1], "key": sys.argv[2], "files": int(sys.argv[3]), "bytes": int(sys.argv[4])}]))' "$vol" "$key" "${vfiles:-0}" "${vbytes:-0}")"
    log "volume backup ok: ${key} (files=${vfiles:-0}, bytes=${vbytes:-0})"
    rm -f "$workdir/vol.tar.gz"
  else
    echo "FAILED to snapshot volume ${vol} (fail closed)." >&2
    FAILED=1
  fi
done <<<"$(docker volume ls -q 2>/dev/null)"

# --- declared bind-mounted host directories (e.g. SQLite directories) ---
for bpath in ${APP_BIND_PATHS:-}; do
  [ -d "$bpath" ] || { echo "FAILED: declared bind path missing: ${bpath}." >&2; FAILED=1; continue; }
  bslug="$(printf '%s' "$bpath" | tr -c 'a-zA-Z0-9' '_' | sed 's/^_*//')"
  key="app-binds/${bslug}-${stamp}.tar.gz"
  if tar czf "$workdir/bind.tar.gz" -C / "${bpath#/}" >/dev/null 2>&1; then
    s3 put-object --bucket "$R2_BUCKET" --key "$key" --body "$workdir/bind.tar.gz"
    s3 head-object --bucket "$R2_BUCKET" --key "$key"
    bfiles="$(find "$bpath" -type f 2>/dev/null | wc -l)"
    manifest_binds="$(printf '%s' "$manifest_binds" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin) + [{"path": sys.argv[1], "key": sys.argv[2], "files": int(sys.argv[3])}]))' "$bpath" "$key" "${bfiles:-0}")"
    log "bind backup ok: ${key} (files=${bfiles:-0})"
    rm -f "$workdir/bind.tar.gz"
  else
    echo "FAILED to snapshot bind path ${bpath} (fail closed)." >&2
    FAILED=1
  fi
done

# --- manifest + retention ---
manifest_key="app-manifests/${stamp}.json"
printf '{"stamp":"%s","databases":%s,"volumes":%s,"binds":%s,"gaps":[]}\n' "$stamp" "$manifest_db" "$manifest_vol" "$manifest_binds" >"$workdir/manifest.json"
s3 put-object --bucket "$R2_BUCKET" --key "$manifest_key" --body "$workdir/manifest.json"
prune_prefix 'app-databases/' 14
prune_prefix 'app-volumes/' 14
prune_prefix 'app-binds/' 14
prune_prefix 'app-manifests/' 14

trap - EXIT
rm -rf "$workdir"
if [ "$FAILED" -ne 0 ]; then
  echo 'one or more workload backups failed (fail closed).' >&2
  exit 2
fi
log 'app-workload backup complete: databases + volumes + manifest in R2, 14-day retention.'
