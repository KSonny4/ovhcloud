#!/usr/bin/env bash
# Application-workload backup to Cloudflare R2 (databases + persistent volumes).
#
# Scope: the actual supported application scope beyond the Nomad cluster
# state (which scripts/schedule-host-backup.sh covers). This script backs
# up, for every application workload on the host:
# - PostgreSQL databases in postgres-image containers (pg_dump custom format),
# - Docker named volumes (tar.gz snapshots),
# plus a JSON manifest of what was captured. Each goes to its R2 prefix with
# 14-day retention pruning.
#
# Excluded by default (infrastructure-owned, documented rationale):
# - Nomad data dir: covered authoritatively by snapshot in schedule-host-backup.sh.
# - cache volumes: ephemeral, safe to lose by design.
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
self_test_input=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --self-test-topology) self_test_input="$2"; shift 2 ;;
    -h|--help) echo 'usage: backup-app-workloads.sh [--dry-run] [--self-test-topology JSONFILE]'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() { printf '%s\n' "$*"; }

# Size-safe upload lib (probe §5 repair: >4 GiB refuse-and-name gate,
# multipart routing, giant excludes, snapshot-save backoff). Resolved at
# call time like the escrow allowlist; absent everywhere = fail closed.
_uplib_dir="$(cd "$(dirname "$0")" && pwd)"
_uplib=''
for _cand in "${_uplib_dir}/backup-upload.sh" "${_uplib_dir}/lib/backup-upload.sh" '/root/host-backup/backup-upload.sh'; do
  if [ -f "$_cand" ]; then _uplib="$_cand"; break; fi
done
if [ -z "$_uplib" ]; then echo 'backup-upload.sh lib missing (fail closed).' >&2; exit 2; fi
# shellcheck disable=SC1090
. "$_uplib"

# Topology extraction (heredoc-quoted python, zero shell interpolation) is
# defined here so --self-test-topology can run it before any root or
# credential checks, and the rehearsal can unit-test the exact live code.
# Takes the docker-inspect JSON FILE as $1 (never stdin: the heredoc owns
# python's stdin, so piping would feed the script itself to json.load).
# Escrow allowlist (lib/escrowed-app-envs, shipped alongside this script;
# absent file = every redaction is operator-relayed, the safe default):
# redacted vars listed there are recorded as escrow-recoverable
# (env_escrowed {var: {path, field}}) so restore re-injects them from
# OpenBao with no human relay.
topology_entry() {
# Resolved at call time (self-test runs repo-side, live runs installed):
# explicit override, beside the script, lib/ beside the script (repo and
# staged layouts), installed dir; absent everywhere = no escrow marking.
allowlist="${ESCROW_ALLOWLIST:-}"
if [ -z "$allowlist" ]; then
  _tdir="$(cd "$(dirname "$0")" && pwd)"
  for _cand in "${_tdir}/escrowed-app-envs" "${_tdir}/lib/escrowed-app-envs" '/root/host-backup/escrowed-app-envs'; do
    if [ -f "$_cand" ]; then allowlist="$_cand"; break; fi
  done
  [ -n "$allowlist" ] || allowlist='/dev/null'
fi
python3 - "$1" "$allowlist" <<'TOPO_PY'
import json,sys
c = json.load(open(sys.argv[1]))[0]
cfg, host, net = c["Config"], c["HostConfig"], c["NetworkSettings"]
escrow = {}
try:
    for line in open(sys.argv[2]):
        parts = line.split()
        if len(parts) == 3 and not parts[0].startswith("#"):
            escrow[parts[0]] = {"path": parts[1], "field": parts[2]}
except OSError:
    pass
env, redacted, env_escrowed = {}, [], {}
for e in cfg.get("Env", []) or []:
    k, _, v = e.partition("=")
    ku = k.upper()
    if any(s in ku for s in ("PASS", "SECRET", "TOKEN", "KEY", "CREDENTIAL")):
        env[k] = "REDACTED"; redacted.append(k)
        if k in escrow:
            env_escrowed[k] = escrow[k]
    else:
        env[k] = v
ports = []
for cport, bindings in (host.get("PortBindings", {}) or {}).items():
    for b in bindings or []:
        hip = b.get("HostIp", "")
        hport = b.get("HostPort", "")
        ports.append((hip + ":" + hport + ":" + cport).lstrip(":"))
# Runtime mounts live TOP-LEVEL (c["Mounts"]), not under HostConfig: reading
# HostConfig.Mounts silently records nothing (always empty there).
mounts = [{"type": m.get("Type"), "source": m.get("Source"), "target": m.get("Destination"), "ro": m.get("Mode","").find("ro") >= 0} for m in (c.get("Mounts", []) or []) if m.get("Type") in ("volume", "bind")]
# Full runtime contract: command/entrypoint (null = image default),
# working directory, container user, restart policy, healthcheck.
runtime = {
    "cmd": cfg.get("Cmd"),
    "entrypoint": cfg.get("Entrypoint"),
    "workdir": cfg.get("WorkingDir", "") or "",
    "user": cfg.get("User", "") or "",
    "restart": (host.get("RestartPolicy", {}) or {}).get("Name", ""),
    "restart_max": (host.get("RestartPolicy", {}) or {}).get("MaximumRetryCount", 0),
    "healthcheck": cfg.get("Healthcheck", {}) or {},
}
print(json.dumps({"name": c["Name"].lstrip("/"), "image": cfg.get("Image"), "env": env, "env_redacted": redacted, "env_escrowed": env_escrowed, "ports": ports, "networks": list((net.get("Networks", {}) or {}).keys()), "labels": cfg.get("Labels", {}) or {}, "mounts": mounts, "runtime": runtime}))
TOPO_PY
}
if [ -n "$self_test_input" ]; then
  topology_entry "$self_test_input"
  exit $?
fi

if [ "$(id -u)" -ne 0 ] && [ "$dry_run" -eq 0 ]; then
  echo 'must run as root.' >&2
  exit 2
fi

exclude="${APP_VOLUME_EXCLUDE:-}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"

if [ "$dry_run" -eq 1 ]; then
  log 'DRY-RUN: enforce workload coverage contract (fail closed on unbackupable mounts/DBs)'
  log 'DRY-RUN: discover postgres containers (pg_dump each non-template DB to R2 app-databases/, record tables+rows)'
  log 'DRY-RUN: snapshot each non-excluded Docker volume to R2 app-volumes/ (record files+bytes)'
  log 'DRY-RUN: snapshot APP_BIND_PATHS + Nomad-discovered host dirs to R2 app-binds/ (giant excludes apply, >4 GiB refused-and-named)'
  log 'DRY-RUN: upload every payload via multipart-routed aws s3 cp (never single-PUT) behind the size gate'
  log 'DRY-RUN: record full container topology (image, env sanitized, ports, networks, labels, mounts) into the manifest'
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
manifest_containers='[]'
FAILED=0

# --- workload coverage contract (fail closed on gaps) ---
# Covered: PostgreSQL databases (native dump), Docker named volumes
# (snapshots; APP_VOLUME_EXCLUDE opts individual volumes out), and host directories
# listed in APP_BIND_PATHS (tar snapshots, e.g. SQLite directories).
# Coverage: every Docker named volume is backed up (cluster state lives in
# /opt/nomad on the host, covered authoritatively by
# schedule-host-backup.sh — it is never a Docker volume, so no exclusion
# is needed). Nomad task containers add two mount classes of their own:
# scheduler-injected ephemeral dirs (/opt/nomad/alloc/*: task local/,
# secrets/, logs/) hold no irreplaceable state and are skipped; host-path
# state under /opt/nomad-volumes/* (cognee store, registry data) is
# auto-covered by the binds snapshot below, except auth material
# (*-auth*, htpasswd) which is OpenBao-canonical and must never be R2-copied.
# Anything stateful that this script cannot back up fails the
# run with an explicit gap list.
system_binds='/etc/hostname /etc/hosts /etc/resolv.conf /etc/resolve.conf /run/docker.sock'
nomad_binds=''
gaps=''
for cname in $(docker ps --format '{{.Names}}' 2>/dev/null || true); do
  case "$cname" in rollback-app-probe-db) continue ;; esac
  [ -n "$cname" ] || continue
  image="$(docker inspect "$cname" --format '{{.Config.Image}}' 2>/dev/null || true)"
  # No platform-image exclusion: every workload image is in scope.
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
    case "$src" in
      /opt/nomad/alloc/*) continue ;;
      /opt/nomad-volumes/*auth*|*/htpasswd) continue ;;
      /opt/nomad-volumes/*)
        if [ -d "$src" ]; then
          case " $nomad_binds " in *" $src "*) ;; *) nomad_binds="${nomad_binds} $src" ;; esac
          continue
        fi ;;
    esac
    declared=0; for b in ${APP_BIND_PATHS:-}; do [ "$src" = "$b" ] && declared=1; done
    if [ "$declared" -eq 0 ]; then
      gaps="${gaps} container ${cname} bind ${src}: undeclared (add to APP_BIND_PATHS or exclude deliberately);"
    fi
  done <<<"$mounts"
done
if [ -n "$gaps" ]; then
  echo "WORKLOAD COVERAGE GAP (fail closed): ${gaps}" >&2
  printf '{"stamp":"%s","databases":[],"volumes":[],"binds":[],"containers":[],"gaps":%s}\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$(printf '%s' "$gaps" | python3 -c 'import json,sys; print(json.dumps([g for g in sys.stdin.read().split(";") if g]))')" >"$workdir/gaps.json"
  backup_upload "$workdir/gaps.json" "app-manifests/gaps-$(date -u +%Y%m%dT%H%M%SZ).json" || true
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
      if backup_upload "$workdir/db.dump.gz" "$key"; then
      # Verifiable counts for restore: tables + total rows (in-service
      # restores must prove data parity, not just readability).
      counts="$("${db_exec[@]}" "$cname" psql -U "$pguser" -d "$db" -tAc "SELECT (SELECT count(*) FROM information_schema.tables WHERE table_schema='public'), coalesce((SELECT sum(n_live_tup)::int FROM pg_stat_user_tables),0);" 2>/dev/null || echo '0|0')"
      tables="${counts%%|*}"; rows="${counts##*|}"
      manifest_db="$(printf '%s' "$manifest_db" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin) + [{"container": sys.argv[1], "image": sys.argv[6], "user": sys.argv[7], "database": sys.argv[2], "key": sys.argv[3], "tables": int(sys.argv[4]), "rows": int(sys.argv[5])}]))' "$cname" "$db" "$key" "${tables:-0}" "${rows:-0}" "$image" "${pguser}")"
      log "database backup ok: ${key} (tables=${tables:-0}, rows=${rows:-0})"
      else
        echo "FAILED to upload ${cname}/${db} key ${key} (fail closed)." >&2
        FAILED=1
      fi
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
    if backup_upload "$workdir/vol.tar.gz" "$key"; then
    volstat="$(docker run --rm -v "${vol}:/data:ro" alpine:3 sh -c 'find /data -type f | wc -l; du -sb /data | cut -f1' 2>/dev/null | awk 'NR==1{f=$1} NR==2{b=$1} END{print f"|"b}' || echo '0|0')"
    vfiles="${volstat%%|*}"; vbytes="${volstat##*|}"
    manifest_vol="$(printf '%s' "$manifest_vol" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin) + [{"volume": sys.argv[1], "key": sys.argv[2], "files": int(sys.argv[3]), "bytes": int(sys.argv[4])}]))' "$vol" "$key" "${vfiles:-0}" "${vbytes:-0}")"
    log "volume backup ok: ${key} (files=${vfiles:-0}, bytes=${vbytes:-0})"
    rm -f "$workdir/vol.tar.gz"
    else
      echo "FAILED to upload volume ${vol} key ${key} (fail closed)." >&2
      FAILED=1
    fi
  else
    echo "FAILED to snapshot volume ${vol} (fail closed)." >&2
    FAILED=1
  fi
done <<<"$(docker volume ls -q 2>/dev/null)"

# --- declared + Nomad-discovered bind-mounted host directories ---
# APP_BIND_PATHS covers Docker-plane state (e.g. SQLite directories);
# nomad_binds (collected above) covers Nomad host-path state. One loop.
for bpath in ${APP_BIND_PATHS:-}${nomad_binds:-}; do
  [ -d "$bpath" ] || { echo "FAILED: declared bind path missing: ${bpath}." >&2; FAILED=1; continue; }
  if backup_bind_excluded "$bpath"; then log "bind skipped (explicit giant exclude, config-only): ${bpath}"; continue; fi
  bslug="$(printf '%s' "$bpath" | tr -c 'a-zA-Z0-9' '_' | sed 's/^_*//')"
  key="app-binds/${bslug}-${stamp}.tar.gz"
  if tar czf "$workdir/bind.tar.gz" -C / "${bpath#/}" >/dev/null 2>&1; then
    if backup_upload "$workdir/bind.tar.gz" "$key"; then
    bfiles="$(find "$bpath" -type f 2>/dev/null | wc -l)"
    manifest_binds="$(printf '%s' "$manifest_binds" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin) + [{"path": sys.argv[1], "key": sys.argv[2], "files": int(sys.argv[3])}]))' "$bpath" "$key" "${bfiles:-0}")"
    log "bind backup ok: ${key} (files=${bfiles:-0})"
    rm -f "$workdir/bind.tar.gz"
    else
      echo "FAILED to upload bind path ${bpath} key ${key} (fail closed)." >&2
      FAILED=1
    fi
  else
    echo "FAILED to snapshot bind path ${bpath} (fail closed)." >&2
    FAILED=1
  fi
done

# --- container topology (for faithful service recreation) ---
# Records every workload container's full topology. Env VALUES are
# recorded except sensitive-looking keys (*PASS*, *SECRET*, *TOKEN*, *KEY*,
# *CREDENTIAL*), which are stored as REDACTED with names listed: recreation
# restores topology + data, and reports exactly which secrets to re-inject.
# Topology entries are produced by topology_entry() (defined near the top).
for cname in $(docker ps --format '{{.Names}}' 2>/dev/null || true); do
  case "$cname" in rollback-app-probe-db) continue ;; esac
  [ -n "$cname" ] || continue
  cspec="$(docker inspect "$cname" 2>/dev/null || true)"
  [ -n "$cspec" ] || { echo "FAILED inspect ${cname}." >&2; FAILED=1; continue; }
  printf '%s' "$cspec" >"$workdir/inspect.json"
  centry="$(topology_entry "$workdir/inspect.json" || true)"
  rm -f "$workdir/inspect.json"
  [ -n "$centry" ] || { echo "FAILED topology ${cname}." >&2; FAILED=1; continue; }
  manifest_containers="$(printf '%s' "$manifest_containers" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin) + [json.loads(sys.argv[1])]))' "$centry")"
  log "topology recorded: ${cname}"
done

# --- manifest + retention ---
manifest_key="app-manifests/${stamp}.json"
printf '{"stamp":"%s","databases":%s,"volumes":%s,"binds":%s,"containers":%s,"gaps":[]}\n' "$stamp" "$manifest_db" "$manifest_vol" "$manifest_binds" "$manifest_containers" >"$workdir/manifest.json"
if ! backup_upload "$workdir/manifest.json" "$manifest_key"; then echo "FAILED to upload manifest ${manifest_key} (fail closed)." >&2; FAILED=1; fi
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
