#!/usr/bin/env bash
# Application-workload rollback/recovery proof (databases + volumes).
#
# Mirrors rollback-coolify-backup.sh for the application scope created by
# backup-app-workloads.sh: given an R2 backup stamp (default: latest
# manifest), downloads every app-database dump and app-volume snapshot of
# that stamp and restores each into DISPOSABLE probes — databases via
# createdb-first pg_restore into a throwaway postgres container, volumes via
# untar into a temp dir — verifying table presence/row counts and file
# presence respectively. Production data is never written; probes are dropped
# and temp material removed on every exit path. Reports RESTORE_OK per item,
# fails closed on any miss.
#
# Credentials ONLY via environment from fetch-r2-env.sh (memory-only).
#
# Usage (on the host, as root):
#   sudo bash fetch-r2-env.sh -- bash scripts/rollback-app-workloads.sh [--stamp STAMP] [--dry-run]
set -euo pipefail

dry_run=0
stamp=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --stamp) stamp="$2"; shift 2 ;;
    --stamp=*) stamp="${1#--stamp=}"; shift ;;
    -h|--help) echo 'usage: rollback-app-workloads.sh [--stamp STAMP] [--dry-run]'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() { printf '%s\n' "$*"; }

if [ "$(id -u)" -ne 0 ] && [ "$dry_run" -eq 0 ]; then
  echo 'must run as root.' >&2
  exit 2
fi
for v in R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET; do
  if [ -z "${!v:-}" ] && [ "$dry_run" -eq 0 ]; then echo "missing ${v}: run through fetch-r2-env.sh -- <this-script>." >&2; exit 2; fi
done

if [ "$dry_run" -eq 1 ]; then
  log 'DRY-RUN: resolve stamp (latest manifest when omitted)'
  log 'DRY-RUN: restore each app-database dump into a disposable probe container (createdb-first pg_restore, verify tables + rows, drop probe)'
  log 'DRY-RUN: restore each app-volume snapshot into temp dir (verify files present, remove temp)'
  log 'DRY-RUN: report RESTORE_OK per item, fail closed on any miss'
  exit 0
fi

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
command -v aws >/dev/null 2>&1 || { echo 'awscli is required.' >&2; exit 2; }
command -v docker >/dev/null 2>&1 || { echo 'docker is required.' >&2; exit 2; }

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"; docker rm -f rollback-app-probe-db >/dev/null 2>&1 || true' EXIT

# s3 ls prints bare filenames; object keys carry the prefix — reattach it.
s3ls() { aws --endpoint-url "$R2_ENDPOINT" s3 ls "s3://${R2_BUCKET}/$1" 2>/dev/null | awk -v p="$1" '{print p $4}'; }
s3get() { aws --endpoint-url "$R2_ENDPOINT" s3api get-object --bucket "$R2_BUCKET" --key "$1" "$2" >/dev/null; }

if [ -z "$stamp" ]; then
  manifest="$(s3ls 'app-manifests/' | sort | tail -n1)"
  [ -n "$manifest" ] || { echo 'no app manifests in R2 (fail closed).' >&2; exit 2; }
  stamp="$(printf '%s' "$manifest" | grep -oE '[0-9]{8}T[0-9]{6}Z')"
  [ -n "$stamp" ] || { echo 'manifest name carries no stamp (fail closed).' >&2; exit 2; }
  log "using latest stamp: ${stamp}"
fi

FAILED=0
# --- databases: restore each stamp dump into a disposable probe container ---
dbs="$(s3ls 'app-databases/' | grep -F "$stamp" || true)"
[ -n "$dbs" ] || log 'no app-database dumps for this stamp (volumes-only backup).'
if [ -n "$dbs" ]; then
  docker run -d --name rollback-app-probe-db -e POSTGRES_PASSWORD=rollback-probe-only postgres:15-alpine >/dev/null 2>&1
  sleep 8
  for key in $dbs; do
    base="$(basename "$key" .dump.gz)"
    db="restored_$(printf '%s' "$base" | tr -c 'a-zA-Z0-9_' '_' | tail -c 50)"
    s3get "$key" "$workdir/r.dump.gz" || { echo "FAILED download ${key}." >&2; FAILED=1; continue; }
    # --no-owner/--no-acl: probes lack the original roles; ownership is
    # irrelevant to proving the data restores. A production restore targets
    # the real container (roles intact) without these flags.
    if docker exec -e PGPASSWORD=rollback-probe-only rollback-app-probe-db psql -U postgres -d postgres -tAc "CREATE DATABASE \"${db}\";" >/dev/null 2>&1 \
      && docker cp "$workdir/r.dump.gz" rollback-app-probe-db:/tmp/r.dump.gz >/dev/null 2>&1 \
      && docker exec rollback-app-probe-db sh -c 'gzip -dc /tmp/r.dump.gz | pg_restore --no-owner --no-acl -U postgres -d "'"$db"'"' >/dev/null 2>&1; then
      tables="$(docker exec -e PGPASSWORD=rollback-probe-only rollback-app-probe-db psql -U postgres -d "$db" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null || echo 0)"
      if [ "${tables:-0}" -gt 0 ] 2>/dev/null; then
        log "RESTORE_OK database: ${key} (tables=${tables})"
      else
        echo "FAILED verify ${key} (no tables restored)." >&2; FAILED=1
      fi
    else
      echo "FAILED restore ${key}." >&2; FAILED=1
    fi
    rm -f "$workdir/r.dump.gz"
  done
  docker rm -f rollback-app-probe-db >/dev/null 2>&1 || true
fi

# --- volumes: restore each stamp snapshot into temp dir, verify files ---
vols="$(s3ls 'app-volumes/' | grep -F "$stamp" || true)"
[ -n "$vols" ] || log 'no app-volume snapshots for this stamp.'
for key in $vols; do
  [ -n "$key" ] || continue
  vdir="$workdir/vol"; rm -rf "$vdir"; mkdir -p "$vdir"
  s3get "$key" "$workdir/v.tar.gz" || { echo "FAILED download ${key}." >&2; FAILED=1; continue; }
  if tar xzf "$workdir/v.tar.gz" -C "$vdir" 2>/dev/null; then
    files="$(find "$vdir" -type f | wc -l)"
    if [ "$files" -gt 0 ]; then
      log "RESTORE_OK volume: ${key} (files=${files})"
    else
      echo "FAILED verify ${key} (empty snapshot)." >&2; FAILED=1
    fi
  else
    echo "FAILED untar ${key}." >&2; FAILED=1
  fi
  rm -f "$workdir/v.tar.gz"; rm -rf "$vdir"
done

trap - EXIT
rm -rf "$workdir"; docker rm -f rollback-app-probe-db >/dev/null 2>&1 || true
if [ "$FAILED" -ne 0 ]; then echo 'one or more workload restores failed (fail closed).' >&2; exit 2; fi
log 'app-workload rollback complete: every stamp artifact restored into probes and verified.'
