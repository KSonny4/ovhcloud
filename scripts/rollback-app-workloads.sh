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
recreate=''
db_password=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --db-password) db_password="$2"; shift 2 ;;
    --db-password=*) db_password="${1#--db-password=}"; shift ;;
    --stamp) stamp="$2"; shift 2 ;;
    --stamp=*) stamp="${1#--stamp=}"; shift ;;
    --recreate) recreate="$2"; shift 2 ;;
    --recreate=*) recreate="${1#--recreate=}"; shift ;;
    -h|--help) echo 'usage: rollback-app-workloads.sh [--stamp STAMP] [--dry-run] [--recreate NAME]'; exit 0 ;;
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
  log 'DRY-RUN: --recreate NAME brings the workload back into service (volumes recreated + snapshots restored, containers recreated from recorded images, dumps restored, counts verified, health checked)'
  log 'DRY-RUN: default probe mode restores each app-database dump into a disposable probe container (createdb-first pg_restore, verify tables + rows, drop probe)'
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

# --- --recreate NAME: bring the workload back into service ---
# Recreates destroyed volumes from snapshots, recreates destroyed containers
# from recorded images, restores dumps with data-parity verification against
# the manifest counts, and health-checks the result. Refuses to clobber
# anything that still exists (fail closed). Consumers re-point to the
# recreated names (original names are reused when the originals are gone).
if [ -n "$recreate" ]; then
  manifest_json="${workdir}/manifest.json"
  manifest_key="$(s3ls 'app-manifests/' | grep -F "$stamp" | head -n1 || true)"
  [ -n "$manifest_key" ] || { echo "no manifest for stamp ${stamp} (fail closed)." >&2; exit 2; }
  s3get "$manifest_key" "$manifest_json" || { echo 'manifest download failed.' >&2; exit 2; }
  # Refuse to clobber live state.
  clashes="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E "^${recreate}(-|$)" || true)"
  [ -z "$clashes" ] || { echo "refusing: live containers match ${recreate}: ${clashes}." >&2; exit 2; }
  vol_clash="$(docker volume ls -q 2>/dev/null | grep -E "^${recreate}-" || true)"
  [ -z "$vol_clash" ] || { echo "refusing: live volumes match ${recreate}: ${vol_clash}." >&2; exit 2; }
  # The recreated superuser password is operator-supplied (fail closed when
  # absent): it becomes the live credential, so it must be known, never
  # invented silently. Pass via environment-backed argv like other stage
  # secrets; it lives only in transient process state.
  [ -n "$db_password" ] || { echo '--recreate requires --db-password (the recreated superuser credential).' >&2; exit 2; }
  newpw="$db_password"; db_password=''
  # Volumes first (containers mount them).
  for vkey in $(python3 -c 'import json,sys; print(" ".join(v["key"] for v in json.load(open(sys.argv[1])).get("volumes",[]) if v.get("volume","").startswith(sys.argv[2]+"-")))' "$manifest_json" "$recreate"); do
    vname="$(python3 -c 'import json,sys; print(next(v["volume"] for v in json.load(open(sys.argv[1])).get("volumes",[]) if v["key"]==sys.argv[2]))' "$manifest_json" "$vkey")"
    vfiles="$(python3 -c 'import json,sys; print(next(v.get("files",0) for v in json.load(open(sys.argv[1])).get("volumes",[]) if v["key"]==sys.argv[2]))' "$manifest_json" "$vkey")"
    docker volume create "$vname" >/dev/null || { echo "FAILED create volume ${vname}." >&2; FAILED=1; continue; }
    s3get "$vkey" "$workdir/v.tar.gz" || { echo "FAILED download ${vkey}." >&2; FAILED=1; continue; }
    if docker run --rm -v "${vname}:/data" -v "${workdir}:/backup" alpine:3 tar xzf /backup/v.tar.gz -C /data >/dev/null 2>&1; then
      got="$(docker run --rm -v "${vname}:/data:ro" alpine:3 sh -c 'find /data -type f | wc -l' 2>/dev/null || echo 0)"
      if [ "${got:-0}" -eq "${vfiles:-0}" ]; then
        log "RESTORED-INTO-SERVICE volume: ${vname} (files=${got})"
      else
        echo "FAILED parity ${vname}: manifest files=${vfiles}, restored=${got}." >&2; FAILED=1
      fi
    else
      echo "FAILED untar ${vkey} into ${vname}." >&2; FAILED=1
    fi
    rm -f "$workdir/v.tar.gz"
  done
  # Containers: one per recorded container name, image from manifest.
  for cname in $(python3 -c 'import json,sys; print(" ".join(sorted({d["container"] for d in json.load(open(sys.argv[1])).get("databases",[]) if d.get("container","").startswith(sys.argv[2]+"-")})))' "$manifest_json" "$recreate"); do
    cimage="$(python3 -c 'import json,sys; print(next(d.get("image","postgres:15-alpine") for d in json.load(open(sys.argv[1])).get("databases",[]) if d["container"]==sys.argv[2]))' "$manifest_json" "$cname")"
    cuser="$(python3 -c 'import json,sys; print(next((d.get("user") or "postgres") for d in json.load(open(sys.argv[1])).get("databases",[]) if d["container"]==sys.argv[2]))' "$manifest_json" "$cname")"
    docker run -d --name "$cname" -e "POSTGRES_USER=${cuser}" -e POSTGRES_PASSWORD="$newpw" "$cimage" >/dev/null 2>&1 || { echo "FAILED start ${cname}." >&2; FAILED=1; continue; }
    sleep 8
    for dkey in $(python3 -c 'import json,sys; print(" ".join(d["key"] for d in json.load(open(sys.argv[1])).get("databases",[]) if d["container"]==sys.argv[2]))' "$manifest_json" "$cname"); do
      dbase="$(python3 -c 'import json,sys; print(next(d["database"] for d in json.load(open(sys.argv[1])).get("databases",[]) if d["key"]==sys.argv[2]))' "$manifest_json" "$dkey")"
      exp_tables="$(python3 -c 'import json,sys; print(next(d.get("tables",0) for d in json.load(open(sys.argv[1])).get("databases",[]) if d["key"]==sys.argv[2]))' "$manifest_json" "$dkey")"
      exp_rows="$(python3 -c 'import json,sys; print(next(d.get("rows",0) for d in json.load(open(sys.argv[1])).get("databases",[]) if d["key"]==sys.argv[2]))' "$manifest_json" "$dkey")"
      s3get "$dkey" "$workdir/r.dump.gz" || { echo "FAILED download ${dkey}." >&2; FAILED=1; continue; }
      if docker exec -e "PGPASSWORD=${newpw}" "$cname" psql -U "$cuser" -d postgres -tAc "CREATE DATABASE \"${dbase}\";" >/dev/null 2>&1 \
        && docker cp "$workdir/r.dump.gz" "$cname:/tmp/r.dump.gz" >/dev/null 2>&1 \
        && docker exec "$cname" sh -c 'gzip -dc /tmp/r.dump.gz | pg_restore --no-owner --no-acl -U '"$cuser"' -d '"$dbase" >/dev/null 2>&1; then
        got_t="$(docker exec -e "PGPASSWORD=${newpw}" "$cname" psql -U "$cuser" -d "$dbase" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null || echo -1)"
        got_r="$(docker exec -e "PGPASSWORD=${newpw}" "$cname" psql -U "$cuser" -d "$dbase" -tAc "SELECT coalesce(sum(n_live_tup)::int,0) FROM pg_stat_user_tables;" 2>/dev/null || echo -1)"
        if [ "${got_t:-0}" -eq "${exp_tables:-0}" ] && [ "${got_r:-0}" -ge "${exp_rows:-0}" ]; then
          log "RESTORED-INTO-SERVICE database: ${cname}/${dbase} (tables=${got_t}, rows=${got_r})"
        else
          echo "FAILED parity ${cname}/${dbase}: expected tables=${exp_tables} rows>=${exp_rows}, got tables=${got_t} rows=${got_r}." >&2; FAILED=1
        fi
      else
        echo "FAILED restore ${dkey} into ${cname}." >&2; FAILED=1
      fi
      rm -f "$workdir/r.dump.gz"
    done
    if docker inspect "$cname" --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
      log "HEALTHY: ${cname} running (replacement superuser password was rotated in at recreate; re-point consumers)."
    else
      echo "FAILED health: ${cname} not running." >&2; FAILED=1
    fi
  done
  trap - EXIT
  rm -rf "$workdir"
  if [ "$FAILED" -ne 0 ]; then echo 'recreate incomplete (fail closed; partial state left for inspection).' >&2; exit 2; fi
  log "recreate complete: workload ${recreate} back in service from stamp ${stamp}."
  exit 0
fi
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
