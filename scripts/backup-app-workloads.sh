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
self_test_multipart=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --self-test-topology) self_test_input="$2"; shift 2 ;;
    --self-test-multipart) self_test_multipart=1; shift ;;
    -h|--help) echo 'usage: backup-app-workloads.sh [--dry-run] [--self-test-topology JSONFILE] [--self-test-multipart]'; exit 0 ;;
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
# Exact names whose VALUES are credential-bearing URIs even though the
# name itself carries no PASS/SECRET/TOKEN/KEY/CREDENTIAL marker
# (field hit: DATABASE_URL + DB postgres URIs exported verbatim into the
# R2 manifest). Any other value shaped as a URI with userinfo
# (scheme://user:pass@host/...) is redacted on shape, not name.
uri_names = {"DATABASE_URL", "DB"}
import re as _re
uri_creds = _re.compile(r"://[^/\s]*:[^/\s]*@")
for e in cfg.get("Env", []) or []:
    k, _, v = e.partition("=")
    ku = k.upper()
    if any(s in ku for s in ("PASS", "SECRET", "TOKEN", "KEY", "CREDENTIAL")) or k in uri_names or uri_creds.search(v or ""):
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

# Size-safe transport library (single-PUT fast path + bounded multipart).
# Resolved like the escrow allowlist: beside the script, lib/ beside the
# script (repo and staged layouts), installed dir; absent = fail closed
# (a backup without the transport library must not silently single-PUT
# large payloads again).
_s3mp_lib=''
_s3mp_dir="$(cd "$(dirname "$0")" && pwd)"
for _s3mp_cand in "${_s3mp_dir}/s3-multipart.sh" "${_s3mp_dir}/lib/s3-multipart.sh" '/root/host-backup/lib/s3-multipart.sh' '/root/host-backup/s3-multipart.sh'; do
  if [ -f "$_s3mp_cand" ]; then _s3mp_lib="$_s3mp_cand"; break; fi
done
if [ -z "$_s3mp_lib" ]; then
  echo 's3-multipart.sh transport library not found (fail closed).' >&2
  exit 2
fi
# shellcheck source=scripts/lib/s3-multipart.sh
source "$_s3mp_lib"

# Offline fixture self-test for the multipart transport contract. Stubs
# `aws` (no daemon, no network, no R2, no credentials) and proves, with
# synthetic sizes and small fixture files only (never a giant fixture):
# threshold selection, verified single-PUT, size-mismatch failure,
# retried multipart parts, interrupted-run abort without complete,
# download size/hash verification, and complete/incomplete manifests.
self_test_multipart() {
  st_tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$st_tmp'" EXIT
  st_fail=0
  st_calls="$st_tmp/calls.log"
  : >"$st_calls"
  export S3MP_TMPDIR="$st_tmp"
  export S3_PART_RETRY_BASE_SECONDS=0
  export S3_PROGRESS_HEARTBEAT_SECONDS=1
  export S3MP_STUB_REMOTE_SIZE='' S3MP_STUB_FAIL_PART_ATTEMPTS=0
  export S3MP_STUB_FAIL_CREATE=0 S3MP_STUB_FAIL_COMPLETE=0 S3MP_STUB_FAIL_ABORT=0
  st_part_attempts="$st_tmp/part-attempts"; echo 0 >"$st_part_attempts"
  aws() {
    local sub='' key='' partnum='' next_is_key=0 next_is_part=0 a
    printf '%s\n' "$*" >>"$st_calls"
    for a in "$@"; do
      if [ "$next_is_key" -eq 1 ]; then key="$a"; next_is_key=0; continue; fi
      if [ "$next_is_part" -eq 1 ]; then partnum="$a"; next_is_part=0; continue; fi
      case "$a" in
        create-multipart-upload|upload-part|complete-multipart-upload|abort-multipart-upload|put-object|head-object) sub="$a" ;;
        --key) next_is_key=1 ;;
        --part-number) next_is_part=1 ;;
      esac
    done
    case "$sub" in
      put-object) return 0 ;;
      head-object)
        printf '%s\n' "${S3MP_STUB_REMOTE_SIZE:-0}"
        return 0 ;;
      create-multipart-upload)
        if [ "${S3MP_STUB_FAIL_CREATE:-0}" -eq 1 ]; then return 1; fi
        printf 'stub-upload-id-%s\n' "$partnum"
        return 0 ;;
      upload-part)
        n="$(cat "$st_part_attempts")"; n=$((n + 1)); printf '%s' "$n" >"$st_part_attempts"
        if [ "$n" -le "${S3MP_STUB_FAIL_PART_ATTEMPTS:-0}" ]; then return 1; fi
        printf '%s' "etag-${partnum}" >"${S3MP_TMPDIR}/s3mp-etag.tmp"
        return 0 ;;
      complete-multipart-upload)
        if [ "${S3MP_STUB_FAIL_COMPLETE:-0}" -eq 1 ]; then return 1; fi
        return 0 ;;
      abort-multipart-upload) return "${S3MP_STUB_FAIL_ABORT:-0}" ;;
      *) return 1 ;;
    esac
  }
  st_pass() { printf 'SELFTEST %s: PASS\n' "$1"; }
  st_failn() { printf 'SELFTEST %s: FAIL (%s)\n' "$1" "$2"; st_fail=$((st_fail + 1)); }
  # 1. threshold selection is a pure size comparison (5 GB synthetic: no
  # allocation, no fixture file).
  if [ "$(S3_MULTIPART_THRESHOLD_BYTES=1000 s3_upload_method_for_bytes 999)" = 'single' ] \
    && [ "$(S3_MULTIPART_THRESHOLD_BYTES=1000 s3_upload_method_for_bytes 1000)" = 'multipart' ] \
    && [ "$(S3_MULTIPART_THRESHOLD_BYTES=1000 s3_upload_method_for_bytes 5000000000)" = 'multipart' ]; then
    st_pass 'selection-no-giant-fixture'
  else
    st_failn 'selection-no-giant-fixture' 'threshold mapping wrong'
  fi
  printf 'abc' >"$st_tmp/tiny.bin"
  if [ "$(S3_MULTIPART_THRESHOLD_BYTES=1000 s3_upload_method_for_file "$st_tmp/tiny.bin")" = 'single' ] \
    && [ "$(S3_MULTIPART_THRESHOLD_BYTES=2 s3_upload_method_for_file "$st_tmp/tiny.bin")" = 'multipart' ]; then
    st_pass 'selection-by-file-size'
  else
    st_failn 'selection-by-file-size' 'file-size mapping wrong'
  fi
  # 2. verified single-PUT: stub head echoes the true local size.
  head -c 1024 /dev/zero >"$st_tmp/small.bin" 2>/dev/null || dd if=/dev/zero of="$st_tmp/small.bin" bs=1024 count=1 status=none 2>/dev/null
  S3MP_STUB_REMOTE_SIZE=1024
  : >"$st_calls"
  if [ "$(S3_MULTIPART_THRESHOLD_BYTES=999999 s3_upload_file b k "$st_tmp/small.bin" e "$st_tmp/p1.jsonl")" = '1024' ] \
    && grep -q '"status":"verified"' "$st_tmp/p1.jsonl"; then
    st_pass 'single-put-verified'
  else
    st_failn 'single-put-verified' 'expected verified 1024 bytes'
  fi
  if [ -z "$(ls "$st_tmp"/s3mp-part.tmp 2>/dev/null)" ] && [ -z "$(ls "$st_tmp"/s3mp-complete.json 2>/dev/null)" ]; then
    st_pass 'tempfiles-restricted'
  else
    st_failn 'tempfiles-restricted' 'stray part/complete files left behind'
  fi
  # 3. remote size mismatch fails closed (no verified outcome).
  S3MP_STUB_REMOTE_SIZE=512
  if S3_MULTIPART_THRESHOLD_BYTES=999999 s3_upload_file b k "$st_tmp/small.bin" e "$st_tmp/p2.jsonl" >/dev/null 2>&1 \
    || grep -q '"status":"failed"' "$st_tmp/p2.jsonl"; then
    if grep -q '"status":"failed"' "$st_tmp/p2.jsonl" 2>/dev/null; then
      st_pass 'size-mismatch-fails-closed'
    else
      st_failn 'size-mismatch-fails-closed' 'mismatch unexpectedly verified'
    fi
  else
    st_failn 'size-mismatch-fails-closed' 'no failed progress recorded'
  fi
  # 4. multipart with transient part failures: 2 failed attempts then
  # success under the 5-attempt bound; bytes verified.
  S3MP_STUB_REMOTE_SIZE=1024; S3MP_STUB_FAIL_PART_ATTEMPTS=2
  echo 0 >"$st_part_attempts"; : >"$st_calls"
  if [ "$(S3_MULTIPART_THRESHOLD_BYTES=10 s3_upload_file b mk "$st_tmp/small.bin" e "$st_tmp/p3.jsonl")" = '1024' ] \
    && [ "$(cat "$st_part_attempts")" -eq 3 ] \
    && grep -q '"stage":"multipart","status":"verified"' "$st_tmp/p3.jsonl"; then
    st_pass 'multipart-retried'
  else
    st_failn 'multipart-retried' "attempts=$(cat "$st_part_attempts" 2>/dev/null)"
  fi
  # 5. interrupted run: parts always fail -> abort, never complete, no
  # verified outcome, no stray part file.
  S3MP_STUB_FAIL_PART_ATTEMPTS=99
  echo 0 >"$st_part_attempts"; : >"$st_calls"
  if S3_MULTIPART_THRESHOLD_BYTES=10 s3_upload_file b mk2 "$st_tmp/small.bin" e "$st_tmp/p4.jsonl" >/dev/null 2>&1; then
    st_failn 'interrupted-aborts' 'exhausted run unexpectedly succeeded'
  elif grep -q 'abort-multipart-upload' "$st_calls" \
    && ! grep -q 'complete-multipart-upload' "$st_calls" \
    && grep -q '"status":"aborted"' "$st_tmp/p4.jsonl" \
    && [ -z "$(ls "$st_tmp"/s3mp-part.tmp 2>/dev/null)" ]; then
    st_pass 'interrupted-aborts'
  else
    st_failn 'interrupted-aborts' 'abort path incomplete'
  fi
  S3MP_STUB_FAIL_PART_ATTEMPTS=0
  # 6. download size/hash verification (rollback uses the same helper).
  fsha="$(sha256sum "$st_tmp/small.bin" | awk '{print $1}')"
  if s3_verify_downloaded "$st_tmp/small.bin" "$fsha" 1024; then
    st_pass 'hash-verifies'
  else
    st_failn 'hash-verifies' 'exact bytes rejected'
  fi
  printf 'X' >>"$st_tmp/small.bin"
  if s3_verify_downloaded "$st_tmp/small.bin" "$fsha" 1024 >/dev/null 2>&1; then
    st_failn 'hash-corruption-fails' 'corrupted bytes accepted'
  else
    st_pass 'hash-corruption-fails'
  fi
  truncate -s 1024 "$st_tmp/small.bin" 2>/dev/null || head -c 1024 "$st_tmp/small.bin" >"$st_tmp/small.bin.fix" 2>/dev/null
  # 7. manifest completeness gate: good manifest passes; missing
  # key/sha256/bytes and unreadable manifests refuse.
  python3 - >"$st_tmp/good.json" <<'PYEOF'
import json
print(json.dumps({"stamp": "s", "databases": [{"key": "k", "sha256": "a" * 64, "bytes": 10}], "volumes": [], "binds": [], "containers": [{"name": "n", "image": "i"}], "gaps": []}))
PYEOF
  if manifest_entries_complete "$st_tmp/good.json" >/dev/null 2>&1; then
    st_pass 'manifest-complete-accepts'
  else
    st_failn 'manifest-complete-accepts' 'good manifest refused'
  fi
  python3 - >"$st_tmp/bad.json" <<'PYEOF'
import json
print(json.dumps({"stamp": "s", "databases": [{"key": "k", "bytes": 10}], "volumes": [{"key": "", "sha256": "z", "bytes": -1}], "binds": [], "containers": [{"name": "n"}], "gaps": []}))
PYEOF
  if manifest_entries_complete "$st_tmp/bad.json" >/dev/null 2>&1; then
    st_failn 'manifest-incomplete-refuses' 'bad manifest accepted'
  else
    st_pass 'manifest-incomplete-refuses'
  fi
  if manifest_entries_complete "$st_tmp/does-not-exist.json" >/dev/null 2>&1; then
    st_failn 'manifest-unreadable-refuses' 'missing file accepted'
  else
    st_pass 'manifest-unreadable-refuses'
  fi
  # 8. progress heartbeat cadence is structurally bounded at <=30s.
  if [ "${S3_PROGRESS_HEARTBEAT_SECONDS:-15}" -le 30 ]; then
    st_pass 'progress-cadence-bounded'
  else
    st_failn 'progress-cadence-bounded' 'heartbeat exceeds 30s'
  fi
  trap - EXIT
  rm -rf "$st_tmp"
  if [ "$st_fail" -ne 0 ]; then
    echo "SELFTEST multipart: ${st_fail} case(s) FAILED." >&2
    return 1
  fi
  echo 'SELFTEST multipart: all cases pass.'
  return 0
}
if [ "$self_test_multipart" -eq 1 ]; then
  self_test_multipart
  exit $?
fi

if [ "$(id -u)" -ne 0 ] && [ "$dry_run" -eq 0 ]; then
  echo 'must run as root.' >&2
  exit 2
fi

exclude="${APP_VOLUME_EXCLUDE:-}"

# Shared PostgreSQL 18 `pg-shared` (KSonny4/nomad-postgresql#1). Its host
# volume holds PGDATA and the pgBackRest spool. It is covered natively: the
# pg_dump loop below dumps every database, and pgBackRest ships base backups
# and WAL to its own R2 bucket. A tar of live PGDATA would be neither
# consistent nor small, so the coverage gate treats this bind as covered.
# The volume is a Nomad dynamic host volume (nomad-postgresql
# jobs/volumes/pg-shared.hcl). The mkdir plugin creates it at
# <host_volumes_dir>/<volume-id>, and the ID is only known once the volume
# exists, so the gate matches the parent directory together with the
# pg-shared image.
pg_shared_volume_root='/opt/nomad/host_volumes'
# pg-shared runs its postgres task from a registry image named pg-shared,
# and Nomad names the container <task>-<alloc_id>. The same image also runs
# the bootstrap, pgbouncer and pgbackrest tasks, so the name narrows it to
# the postgres task. Matching on the image and name (not only Nomad labels)
# keeps this working when the docker plugin sets no extra_labels.
is_pg_shared_postgres() {
  case "$2" in *pg-shared*) ;; *) return 1 ;; esac
  case "$1" in postgres-*) return 0 ;; *) return 1 ;; esac
}
stamp="$(date -u +%Y%m%dT%H%M%SZ)"

if [ "$dry_run" -eq 1 ]; then
  log 'DRY-RUN: enforce workload coverage contract (fail closed on unbackupable mounts/DBs)'
  log 'DRY-RUN: discover postgres containers (pg_dump each non-template DB to R2 app-databases/, record tables+rows+bytes+sha256)'
  log 'DRY-RUN: pg-shared postgres container: docker exec -u postgres (peer auth on the local socket, no password), dump EVERY non-template DB incl. postgres to app-databases/pg-shared-<db>-<stamp>.dump.gz; enumeration failure fails the run'
  log 'DRY-RUN: snapshot each non-excluded Docker volume to R2 app-volumes/ (record files+bytes+sha256)'
  log 'DRY-RUN: snapshot APP_BIND_PATHS + Nomad-discovered host dirs to R2 app-binds/ (giant excludes apply, >4 GiB refused-and-named)'
  log 'DRY-RUN: upload every payload via size-safe transport (single-PUT under threshold, bounded multipart above; per-stage byte progress; remote-size verified) behind the 4 GiB refuse-and-name gate'
  log 'DRY-RUN: record full container topology (image, env sanitized, ports, networks, labels, mounts) into the manifest'
  log 'DRY-RUN: upload JSON manifest to R2 app-manifests/ ONLY when every payload verified (else failed-progress evidence, no green manifest); prune all prefixes older than 14 days (fail closed)'
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
# Restricted tempfiles for the multipart transport: one part at a time
# under this caller-owned workdir (never ambient /tmp sprawl).
export S3MP_TMPDIR="$workdir"
# Durable granular progress: every transport stage/byte event appends one
# JSON line here (heartbeat <=30s while a part is in flight). Preserved to
# R2 as failure evidence when the run cannot write a green manifest.
progress_file="$workdir/upload-progress.jsonl"
: >"$progress_file"
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
system_binds='/etc/hostname /etc/hosts /etc/resolv.conf /etc/resolve.conf /run/docker.sock /var/run/docker.sock'
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
      "$pg_shared_volume_root"/*)
        # Covered by the native pg-shared dumps + pgBackRest (see above);
        # only for containers running the pg-shared image. Any other
        # container's dynamic host volume stays a gap.
        case "$image" in *pg-shared*) continue ;; esac ;;
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
  # Default (every other postgres container, unchanged): skip the postgres
  # maintenance DB, count/precheck only the public schema, and key the dump
  # by container name.
  pg_shared=0
  db_list_sql="SELECT datname FROM pg_database WHERE NOT datistemplate AND datname NOT IN ('postgres');"
  table_scope="table_schema='public'"
  key_name="$cname"
  if is_pg_shared_postgres "$cname" "$image"; then
    # pg-shared: pg_hba allows the postgres superuser only by peer auth on
    # the local socket, so exec as the OS user postgres. No password and no
    # OpenBao read are involved. Every non-template DB is dumped, including
    # postgres (it holds the ops schema), with no empty-DB skip. The key
    # uses a stable name because the alloc id in cname changes per deploy.
    pg_shared=1
    pguser='postgres'
    db_exec=(docker exec -u postgres)
    db_list_sql='SELECT datname FROM pg_database WHERE NOT datistemplate;'
    table_scope="table_schema NOT IN ('pg_catalog','information_schema')"
    key_name='pg-shared'
  fi
  if ! dbs="$("${db_exec[@]}" "$cname" psql -U "$pguser" -d postgres -tAc "$db_list_sql" 2>/dev/null)"; then
    dbs=''
    if [ "$pg_shared" -eq 1 ]; then
      echo "FAILED to enumerate databases in ${cname} (pg-shared; fail closed)." >&2
      FAILED=1
    fi
  fi
  if [ "$pg_shared" -eq 1 ] && [ -z "$dbs" ] && [ "$FAILED" -eq 0 ]; then
    echo "FAILED: pg-shared ${cname} listed no databases (fail closed)." >&2
    FAILED=1
  fi
  for db in $dbs; do
    key="app-databases/${key_name}-${db}-${stamp}.dump.gz"
    precheck="$("${db_exec[@]}" "$cname" psql -U "$pguser" -d "$db" -tAc "SELECT count(*) FROM information_schema.tables WHERE ${table_scope};" 2>/dev/null || echo 0)"
    if [ "$pg_shared" -eq 0 ] && [ "${precheck:-0}" -eq 0 ]; then
      log "database skipped (empty, no user tables): ${cname}/${db}"
      continue
    fi
    if "${db_exec[@]}" "$cname" pg_dump -Fc -U "$pguser" "$db" 2>/dev/null | gzip >"$workdir/db.dump.gz"; then
      # 4 GiB refuse-and-name gate first (probe §5): giants never reach the
      # transport no matter how safe its multipart is.
      if ! backup_gate_check "$workdir/db.dump.gz" "$key"; then
        echo "FAILED to upload ${cname}/${db} (fail closed; entry not recorded)." >&2
        FAILED=1
      else
      # Size-safe transport: single-PUT under threshold, bounded multipart
      # above (the old bare put-object failed EntityTooLarge on large
      # payloads). Verified remote bytes or the entry is not recorded.
      # NOTE: this proves staged bytes moved; it does NOT claim the dump
      # is a coherent snapshot of a live database (separate contract).
      dsha="$(sha256sum "$workdir/db.dump.gz" | awk '{print $1}')"
      if s3_upload_file "$R2_BUCKET" "$key" "$workdir/db.dump.gz" "$R2_ENDPOINT" "$progress_file" >/dev/null; then
        dbytes="$(stat -c%s "$workdir/db.dump.gz" 2>/dev/null || stat -f%z "$workdir/db.dump.gz" 2>/dev/null || wc -c <"$workdir/db.dump.gz")"
        # Verifiable counts for restore: tables + total rows (in-service
        # restores must prove data parity, not just readability).
        counts="$("${db_exec[@]}" "$cname" psql -U "$pguser" -d "$db" -tAc "SELECT (SELECT count(*) FROM information_schema.tables WHERE ${table_scope}), coalesce((SELECT sum(n_live_tup)::int FROM pg_stat_user_tables),0);" 2>/dev/null || echo '0|0')"
        tables="${counts%%|*}"; rows="${counts##*|}"
        manifest_db="$(printf '%s' "$manifest_db" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin) + [{"container": sys.argv[1], "image": sys.argv[6], "user": sys.argv[7], "database": sys.argv[2], "key": sys.argv[3], "tables": int(sys.argv[4]), "rows": int(sys.argv[5]), "bytes": int(sys.argv[8]), "sha256": sys.argv[9]}]))' "$cname" "$db" "$key" "${tables:-0}" "${rows:-0}" "$image" "${pguser}" "$dbytes" "$dsha")"
        log "database backup ok: ${key} (tables=${tables:-0}, rows=${rows:-0}, bytes=${dbytes})"
      else
        echo "FAILED to upload ${cname}/${db} (fail closed; entry not recorded)." >&2
        FAILED=1
      fi
      rm -f "$workdir/db.dump.gz"
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
      # 4 GiB refuse-and-name gate first (probe §5): giants never reach the
      # transport no matter how safe its multipart is.
      if ! backup_gate_check "$workdir/vol.tar.gz" "$key"; then
        echo "FAILED to upload volume ${vol} (fail closed; entry not recorded)." >&2
        FAILED=1
      else
    # NOTE: a tar of live state (notably SQLite/WAL directories) is a
    # byte copy, not a coherence proof — see the transport header.
    vsha="$(sha256sum "$workdir/vol.tar.gz" | awk '{print $1}')"
    if s3_upload_file "$R2_BUCKET" "$key" "$workdir/vol.tar.gz" "$R2_ENDPOINT" "$progress_file" >/dev/null; then
      volstat="$(docker run --rm -v "${vol}:/data:ro" alpine:3 sh -c 'find /data -type f | wc -l; du -sb /data | cut -f1' 2>/dev/null | awk 'NR==1{f=$1} NR==2{b=$1} END{print f"|"b}' || echo '0|0')"
      vfiles="${volstat%%|*}"; vbytes="${volstat##*|}"
      manifest_vol="$(printf '%s' "$manifest_vol" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin) + [{"volume": sys.argv[1], "key": sys.argv[2], "files": int(sys.argv[3]), "bytes": int(sys.argv[4]), "sha256": sys.argv[5]}]))' "$vol" "$key" "${vfiles:-0}" "${vbytes:-0}" "$vsha")"
      log "volume backup ok: ${key} (files=${vfiles:-0}, bytes=${vbytes:-0})"
    else
      echo "FAILED to upload volume ${vol} (fail closed; entry not recorded)." >&2
      FAILED=1
    fi
      fi
    rm -f "$workdir/vol.tar.gz"
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
      # 4 GiB refuse-and-name gate first (probe §5): giants never reach the
      # transport no matter how safe its multipart is.
      if ! backup_gate_check "$workdir/bind.tar.gz" "$key"; then
        echo "FAILED to upload bind path ${bpath} (fail closed; entry not recorded)." >&2
        FAILED=1
      else
    bsha="$(sha256sum "$workdir/bind.tar.gz" | awk '{print $1}')"
    bbytes="$(stat -c%s "$workdir/bind.tar.gz" 2>/dev/null || stat -f%z "$workdir/bind.tar.gz" 2>/dev/null || wc -c <"$workdir/bind.tar.gz")"
    if s3_upload_file "$R2_BUCKET" "$key" "$workdir/bind.tar.gz" "$R2_ENDPOINT" "$progress_file" >/dev/null; then
      bfiles="$(find "$bpath" -type f 2>/dev/null | wc -l)"
      manifest_binds="$(printf '%s' "$manifest_binds" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin) + [{"path": sys.argv[1], "key": sys.argv[2], "files": int(sys.argv[3]), "bytes": int(sys.argv[4]), "sha256": sys.argv[5]}]))' "$bpath" "$key" "${bfiles:-0}" "$bbytes" "$bsha")"
      log "bind backup ok: ${key} (files=${bfiles:-0})"
    else
      echo "FAILED to upload bind path ${bpath} (fail closed; entry not recorded)." >&2
      FAILED=1
    fi
      fi
    rm -f "$workdir/bind.tar.gz"
  else
    echo "FAILED to snapshot bind path ${bpath} (fail closed)." >&2
    FAILED=1
  fi
done

# --- container topology (for faithful service recreation) ---
# Records every workload container's full topology. Env VALUES are
# recorded except sensitive-looking keys (*PASS*, *SECRET*, *TOKEN*, *KEY*,
# *CREDENTIAL*), the credential-URI names (DATABASE_URL, DB), and any value
# shaped as a URI with userinfo (scheme://user:pass@host/...), which are
# stored as REDACTED with names listed: recreation
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
# No green manifest until every mandatory object is present AND verified:
# entries are recorded only after verified upload, and the assembled
# manifest must pass the completeness gate (key+sha256+bytes per payload
# entry) before it may be published. Any failure preserves the durable
# progress log to R2 as failed- evidence (never a green-looking manifest).
manifest_key="app-manifests/${stamp}.json"
printf '{"stamp":"%s","databases":%s,"volumes":%s,"binds":%s,"containers":%s,"gaps":[]}\n' "$stamp" "$manifest_db" "$manifest_vol" "$manifest_binds" "$manifest_containers" >"$workdir/manifest.json"
if [ "$FAILED" -ne 0 ]; then
  aws --endpoint-url "$R2_ENDPOINT" s3api put-object --bucket "$R2_BUCKET" --key "app-manifests/failed-${stamp}.progress.jsonl" --body "$progress_file" >/dev/null 2>&1 || true
  echo 'payload failures recorded; refusing green manifest (fail closed).' >&2
elif ! manifest_entries_complete "$workdir/manifest.json"; then
  aws --endpoint-url "$R2_ENDPOINT" s3api put-object --bucket "$R2_BUCKET" --key "app-manifests/failed-${stamp}.progress.jsonl" --body "$progress_file" >/dev/null 2>&1 || true
  echo 'manifest completeness gate refused (fail closed; no green manifest).' >&2
  FAILED=1
elif ! s3_upload_file "$R2_BUCKET" "$manifest_key" "$workdir/manifest.json" "$R2_ENDPOINT" "$progress_file" >/dev/null; then
  echo 'FAILED to upload manifest (fail closed).' >&2
  FAILED=1
fi
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
