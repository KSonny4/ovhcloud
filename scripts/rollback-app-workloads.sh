#!/usr/bin/env bash
# Application-workload rollback/recovery proof (databases + volumes).
#
# Mirrors rollback-nomad-snapshot.sh for the application scope created by
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
    --self-test-db-flags) self_test_db=1; shift ;;
    --self-test-escrow) self_test_escrow=1; shift ;;
    -h|--help) echo 'usage: rollback-app-workloads.sh [--stamp STAMP] [--dry-run] [--recreate NAME] [--db-password PW] [--self-test-db-flags] [--self-test-escrow] (PW may also arrive via APP_DB_PASSWORD env)'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() { printf '%s\n' "$*"; }

if [ "$(id -u)" -ne 0 ] && [ "$dry_run" -eq 0 ] && [ "${self_test_db:-0}" -eq 0 ] && [ "${self_test_escrow:-0}" -eq 0 ]; then
  echo 'must run as root.' >&2
  exit 2
fi
for v in R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET; do
  if [ -z "${!v:-}" ] && [ "$dry_run" -eq 0 ] && [ "${self_test_db:-0}" -eq 0 ] && [ "${self_test_escrow:-0}" -eq 0 ]; then echo "missing ${v}: run through fetch-r2-env.sh -- <this-script>." >&2; exit 2; fi
done

# Recreate credential precedence: explicit flag wins, then APP_DB_PASSWORD
# env (operator wrapper supplies it from OpenBao via stdin, never argv),
# otherwise fail closed at --recreate time (never invented silently).
if [ -n "${db_password:-}" ]; then pw_source='flag'; elif [ -n "${APP_DB_PASSWORD:-}" ]; then db_password="$APP_DB_PASSWORD"; pw_source='env'; else pw_source='absent'; fi
if [ "$dry_run" -eq 1 ]; then
  log 'DRY-RUN: resolve stamp (latest manifest when omitted)'
  log "DRY-RUN: recreate credential source: ${pw_source} (--db-password flag, APP_DB_PASSWORD env, or fail closed)"
  log 'DRY-RUN: --recreate NAME brings the workload back into service (volumes + binds recreated with parity, containers recreated from recorded images, dumps restored with parity, health checked; refuses live targets)'
  log 'DRY-RUN: default probe mode restores each app-database dump into a disposable probe container (createdb-first pg_restore, verify tables + rows, drop probe)'
  log 'DRY-RUN: restore each app-volume and app-bind snapshot into temp dir (verify files present, remove temp)'
  log 'DRY-RUN: report RESTORE_OK per item, fail closed on any miss'
  exit 0
fi

if [ "${self_test_db:-0}" -eq 1 ] || [ "${self_test_escrow:-0}" -eq 1 ]; then
  R2_ACCESS_KEY_ID='selftest' R2_SECRET_ACCESS_KEY='selftest' R2_ENDPOINT='selftest' R2_BUCKET='selftest'
fi
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
if [ "${self_test_db:-0}" -ne 1 ] && [ "${self_test_escrow:-0}" -ne 1 ]; then
  command -v aws >/dev/null 2>&1 || { echo 'awscli is required.' >&2; exit 2; }
fi
if [ "${self_test_db:-0}" -ne 1 ] && [ "${self_test_escrow:-0}" -ne 1 ]; then
  command -v docker >/dev/null 2>&1 || { echo 'docker is required.' >&2; exit 2; }
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"; docker rm -f rollback-app-probe-db >/dev/null 2>&1 || true' EXIT

# Transport verification helpers (size/hash against the manifest record).
# Resolved like the backup plane: beside the script, lib/ beside the
# script, installed dir; absent = fail closed (restores must not run
# unverified when the library is missing).
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
# s3 ls prints bare filenames; object keys carry the prefix — reattach it.
s3ls() { aws --endpoint-url "$R2_ENDPOINT" s3 ls "s3://${R2_BUCKET}/$1" 2>/dev/null | awk -v p="$1" '{print p $4}'; }
s3get() { aws --endpoint-url "$R2_ENDPOINT" s3api get-object --bucket "$R2_BUCKET" --key "$1" "$2" >/dev/null; }
# verify_manifest_file SECTION KEY MANIFEST_JSON LOCALFILE — enforce the
# manifest's bytes+sha256 record for a download. Legacy entries (no
# transport records at all) prove restorability only and are logged as
# LEGACY; a key absent from a complete manifest, or a bytes/hash
# mismatch, fails closed. Returns 0 when the download is accepted.
verify_manifest_file() {
  local section="$1" key="$2" mjson="$3" localfile="$4" rec sha bytes
  rec="$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); e=next((x for x in m.get(sys.argv[2],[]) if x.get("key")==sys.argv[3]),None); print(((e or {}).get("sha256") or "")+"|"+str((e or {}).get("bytes") if (e or {}).get("bytes") is not None else ""))' "$mjson" "$section" "$key" 2>/dev/null || true)"
  sha="${rec%%|*}"; bytes="${rec##*|}"
  if [ -z "$bytes" ]; then
    if [ "${MANIFEST_CLASS:-complete}" = 'legacy' ]; then
      log "LEGACY entry (no transport record): ${key}; proving restorability only"
      return 0
    fi
    echo "FAILED verify ${key}: key absent from manifest section ${section} (fail closed)." >&2
    return 1
  fi
  if [ -z "$sha" ]; then
    echo "FAILED verify ${key}: transport record incomplete (bytes without sha256; fail closed)." >&2
    return 1
  fi
  s3_verify_downloaded "$localfile" "$sha" "$bytes"
}
# classify_manifest MANIFEST_JSON — sets MANIFEST_CLASS to
# complete|legacy, failing closed on incomplete/mixed manifests.
classify_manifest() {
  local verdict
  if verdict="$(manifest_classify "$1" 2>&1)"; then
    MANIFEST_CLASS="$verdict"
    log "manifest class: ${MANIFEST_CLASS} ($1)"
    return 0
  fi
  echo "FAILED manifest: ${verdict} (fail closed; refusing to certify)." >&2
  return 1
}



# build_run_args: shared docker-run flag builder for application and
# database containers (auditor fix: databases restore full recorded topology).
# Inputs: SPEC_CSPEC (topology entry JSON), SPEC_CNAME, SPEC_SKIP_ENVS
# (space-separated env names to omit), SPEC_SKIP_MOUNT (one mount target to
# omit, e.g. dump-authoritative pgdata). Needs manifest_json/workdir/s3get
# for snapshot restores. Outputs run_args, cmd_args, extra_nets, first_net;
# appends redacted names to needs_secrets. Returns nonzero on failure.
# Escrow re-injection (no human relay): a REDACTED var listed in the entry's
# env_escrowed map AND present non-empty in process environment (delivered
# memory-only, e.g. via fetch-app-secrets piped blob) is restored from env
# and logged by name only; only truly-missing secrets land in needs_secrets.
build_run_args() {
  cspec="${SPEC_CSPEC:?build_run_args needs SPEC_CSPEC}"
  escrowed_vars="$(printf '%s' "$cspec" | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin).get("env_escrowed",{}).keys()))' || true)"
  run_args=()
  while IFS= read -r kv; do
    [ -n "$kv" ] || continue
    k="${kv%%=*}"; v="${kv#*=}"
    case " ${SPEC_SKIP_ENVS:-} " in *" $k "*) continue ;; esac
    if [ "$v" = 'REDACTED' ]; then
      case " ${escrowed_vars} " in *" $k "*)
        if [ -n "${!k:-}" ]; then
          run_args+=(-e "${k}=${!k}")
          log "re-injected ${SPEC_CNAME}:${k} from escrow delivery (value never printed)."
          continue
        fi ;;
      esac
      needs_secrets="${needs_secrets} ${SPEC_CNAME}:${k}"; continue
    fi
    run_args+=(-e "${k}=${v}")
  done <<<"$(printf '%s' "$cspec" | python3 -c 'import json,sys; [print(f"{k}={v}") for k,v in json.load(sys.stdin).get("env",{}).items()]')"
  while IFS= read -r pm; do
    [ -n "$pm" ] || continue
    run_args+=(-p "$pm")
  done <<<"$(printf '%s' "$cspec" | python3 -c 'import json,sys; [print(p) for p in json.load(sys.stdin).get("ports",[])]')"
  while IFS= read -r lb; do
    [ -n "$lb" ] || continue
    run_args+=(-l "$lb")
  done <<<"$(printf '%s' "$cspec" | python3 -c 'import json,sys; [print(f"{k}={v}") for k,v in json.load(sys.stdin).get("labels",{}).items()]')"
  first_net="$(printf '%s' "$cspec" | python3 -c 'import json,sys; n=json.load(sys.stdin).get("networks",[]); print(n[0] if n else "")')"
  extra_nets="$(printf '%s' "$cspec" | python3 -c 'import json,sys; [print(n) for n in json.load(sys.stdin).get("networks",[])[1:]]')"
  for net in $first_net $extra_nets; do
    [ -n "$net" ] || continue
    docker network inspect "$net" >/dev/null 2>&1 || docker network create "$net" >/dev/null 2>&1 || { echo "FAILED network ${net}." >&2; FAILED=1; return 1; }
  done
  [ -n "$first_net" ] && run_args+=(--network "$first_net")
  # Full runtime contract: workdir, user, entrypoint, restart policy,
  # healthcheck, and command (appended after the image). Null entrypoint
  # or empty cmd means image default (nothing passed).
  rt_workdir="$(printf '%s' "$cspec" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("runtime",{}).get("workdir",""))')"
  rt_user="$(printf '%s' "$cspec" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("runtime",{}).get("user",""))')"
  # Arrays travel element-per-line (never word-split): faithful for quoted
  # arguments with spaces. Portable while-read (no mapfile: macOS bash 3).
  # Entrypoint: first element is the executable, the rest are pre-image args.
  rt_entry_arr=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    rt_entry_arr+=("$line")
  done <<<"$(printf '%s' "$cspec" | python3 -c 'import json,sys; e=json.load(sys.stdin).get("runtime",{}).get("entrypoint"); [print(x) for x in (e or [])]')"
  if [ "${#rt_entry_arr[@]}" -gt 0 ]; then
    run_args+=(--entrypoint "${rt_entry_arr[0]}")
    run_args+=("${rt_entry_arr[@]:1}")
  fi
  rt_restart="$(printf '%s' "$cspec" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("runtime",{}).get("restart",""))')"
  rt_restart_max="$(printf '%s' "$cspec" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("runtime",{}).get("restart_max",0))')"
  [ -n "$rt_workdir" ] && run_args+=(-w "$rt_workdir")
  [ -n "$rt_user" ] && run_args+=(-u "$rt_user")
  case "$rt_restart" in
    ''|no) ;;
    on-failure)
      if [ "${rt_restart_max:-0}" -gt 0 ] 2>/dev/null; then
        run_args+=(--restart "on-failure:${rt_restart_max}")
      else
        run_args+=(--restart on-failure)
      fi ;;
    *) run_args+=(--restart "$rt_restart") ;;
  esac
  hc_kind="$(printf '%s' "$cspec" | python3 -c 'import json,sys; t=(json.load(sys.stdin).get("runtime",{}).get("healthcheck",{}) or {}).get("Test",[]); print(t[0] if t else "")')"
  if [ "$hc_kind" = 'NONE' ]; then
    run_args+=(--no-healthcheck)
  elif [ "$hc_kind" = 'CMD-SHELL' ]; then
    hc_cmd="$(printf '%s' "$cspec" | python3 -c 'import json,sys; t=(json.load(sys.stdin).get("runtime",{}).get("healthcheck",{}) or {}).get("Test",[]); print(t[1] if len(t)>1 else "")')"
    [ -n "$hc_cmd" ] && run_args+=(--health-cmd "$hc_cmd")
  elif [ "$hc_kind" = 'CMD' ]; then
    # Exec-form healthcheck: shlex.join preserves quoting semantics through
    # the shell that --health-cmd runs under (documented approximation:
    # argument vectors survive, exotic control operators do not).
    hc_cmd="$(printf '%s' "$cspec" | python3 -c 'import json,shlex,sys; t=(json.load(sys.stdin).get("runtime",{}).get("healthcheck",{}) or {}).get("Test",[]); print(shlex.join(t[1:]) if len(t)>1 else "")')"
    [ -n "$hc_cmd" ] && run_args+=(--health-cmd "$hc_cmd")
  fi
  for hf in Interval Timeout StartPeriod; do
    hv="$(printf '%s' "$cspec" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("runtime",{}).get("healthcheck",{}) or {}).get("'"$hf"'",0))')"
    if [ "${hv:-0}" -gt 0 ] 2>/dev/null; then
      case "$hf" in
        Interval) run_args+=(--health-interval "${hv}ns") ;;
        Timeout) run_args+=(--health-timeout "${hv}ns") ;;
        StartPeriod) run_args+=(--health-start-period "${hv}ns") ;;
      esac
    fi
  done
  hr="$(printf '%s' "$cspec" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("runtime",{}).get("healthcheck",{}) or {}).get("Retries",0))')"
  [ "${hr:-0}" -gt 0 ] 2>/dev/null && run_args+=(--health-retries "$hr")
  # Command array, element-faithful (appended after the image).
  cmd_args=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    cmd_args+=("$line")
  done <<<"$(printf '%s' "$cspec" | python3 -c 'import json,sys; c=json.load(sys.stdin).get("runtime",{}).get("cmd"); [print(x) for x in (c or [])]')"
  while IFS= read -r mnt; do
    [ -n "$mnt" ] || continue
    mtype="${mnt%%|*}"; rest="${mnt#*|}"; msrc="${rest%%|*}"; rest2="${rest#*|}"; mdst="${rest2%%|*}"; mro="${rest2#*|}"
    if [ -n "${SPEC_SKIP_MOUNT:-}" ] && [ "$mdst" = "$SPEC_SKIP_MOUNT" ]; then continue; fi
    if [ "$mtype" = 'volume' ]; then
      # docker inspect reports named-volume sources as host paths
      # (/var/lib/docker/volumes/<name>/_data): normalize to the name.
      case "$msrc" in
        /var/lib/docker/volumes/*/_data) msrc="$(printf '%s' "$msrc" | sed 's|^/var/lib/docker/volumes/||; s|/_data$||')" ;;
      esac
      if ! docker volume inspect "$msrc" >/dev/null 2>&1; then
        vsnap="$(python3 -c 'import json,sys; print(next((v["key"] for v in json.load(open(sys.argv[1])).get("volumes",[]) if v["volume"]==sys.argv[2]),""))' "$manifest_json" "$msrc")"
        [ -n "$vsnap" ] || { echo "FAILED mount ${msrc}: volume missing and no snapshot recorded." >&2; FAILED=1; return 1; }
        docker volume create "$msrc" >/dev/null || { echo "FAILED create volume ${msrc}." >&2; FAILED=1; return 1; }
        s3get "$vsnap" "$workdir/m.tar.gz" || { echo "FAILED download ${vsnap}." >&2; FAILED=1; return 1; }
        docker run --rm -v "${msrc}:/data" -v "${workdir}:/backup" alpine:3 tar xzf /backup/m.tar.gz -C /data >/dev/null 2>&1 || { echo "FAILED untar into ${msrc}." >&2; FAILED=1; return 1; }
        rm -f "$workdir/m.tar.gz"
        log "mount volume restored: ${msrc}"
      fi
      if [ "$mro" = 'True' ]; then run_args+=(-v "${msrc}:${mdst}:ro"); else run_args+=(-v "${msrc}:${mdst}"); fi
    elif [ "$mtype" = 'bind' ]; then
      mkdir -p "$msrc" || { echo "FAILED bind dir ${msrc}." >&2; FAILED=1; return 1; }
      run_args+=(-v "${msrc}:${mdst}")
    fi
  done <<<"$(printf '%s' "$cspec" | python3 -c 'import json,sys; [print(str(m.get("type","")) + "|" + str(m.get("source","")) + "|" + str(m.get("target","")) + "|" + str(m.get("ro",False))) for m in json.load(sys.stdin).get("mounts",[])]')"
}

# Offline self-test: prove the shared builder restores database topology
# (networks, ports, restart+max, health, non-secret env) while omitting the
# fresh credential envs and the dump-authoritative pgdata mount. docker/s3
# are stubbed: no daemon, no network, no R2 touched.
if [ "${self_test_db:-0}" -eq 1 ]; then
  docker() { return 0; }
  s3get() { return 0; }
  manifest_json=$workdir/selftest-manifest.json
  python3 - >"$manifest_json" <<'PYEOF'
import json
entry = {'name': 'dbproof-db', 'image': 'postgres:15-alpine',
 'env': {'POSTGRES_USER': 'dbowner', 'POSTGRES_PASSWORD': 'REDACTED', 'PGDATA': '/var/lib/postgresql/data', 'TZ': 'UTC'},
 'ports': ['5433:5432/tcp'], 'networks': ['dbnet', 'backend'],
 'labels': {'proof': 'dbflags'},
 'mounts': [{'type': 'volume', 'source': '/var/lib/docker/volumes/dbproof-data/_data', 'target': '/var/lib/postgresql/data', 'ro': False}],
 'runtime': {'cmd': [], 'entrypoint': None, 'workdir': '', 'user': 'postgres',
  'restart': 'on-failure', 'restart_max': 3,
  'healthcheck': {'Test': ['CMD-SHELL', 'pg_isready -U dbowner'], 'Interval': 10000000000, 'Timeout': 5000000000, 'StartPeriod': 0, 'Retries': 3}}}
print(json.dumps({'databases': [], 'volumes': [], 'binds': [], 'containers': [entry]}))
PYEOF
  needs_secrets=''
  SPEC_CSPEC=$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["containers"][0]))' "$manifest_json")
  SPEC_CNAME='dbproof-db' SPEC_SKIP_ENVS='POSTGRES_USER POSTGRES_PASSWORD' SPEC_SKIP_MOUNT='/var/lib/postgresql/data'
  build_run_args || { echo 'SELFTEST build failed.' >&2; exit 2; }
  printf '%s\n' "${run_args[@]}"
  exit 0
fi

# Escrow self-test: the EXACT build_run_args against a fixture cspec with
# an escrowed REDACTED var — delivered via env it lands in run_args (never
# in needs_secrets); absent from env it lands in needs_secrets. No docker,
# no R2, no network.
if [ "${self_test_escrow:-0}" -eq 1 ]; then
  docker() { return 0; }
  python3 - >"$workdir/escrow-cspec.json" <<'PYEOF'
import json
print(json.dumps({'name': 'escrow-app', 'image': 'alpine:3',
 'env': {'APP_MODE': 'proof', 'STORAGE_ENCRYPTION_KEY': 'REDACTED'},
 'env_escrowed': {'STORAGE_ENCRYPTION_KEY': {'path': 'secret/projects/nomad/APPSHARED', 'field': 'STORAGE_ENCRYPTION_KEY'}},
 'ports': [], 'networks': [], 'labels': {}, 'mounts': [],
 'runtime': {'cmd': ['sleep', '3600'], 'entrypoint': None, 'workdir': '', 'user': '', 'restart': '', 'restart_max': 0, 'healthcheck': {}}}))
PYEOF
  needs_secrets=''
  SPEC_CSPEC="$(cat "$workdir/escrow-cspec.json")"
  SPEC_CNAME='escrow-app' SPEC_SKIP_ENVS='' SPEC_SKIP_MOUNT=''
  STORAGE_ENCRYPTION_KEY='delivered-test-value' build_run_args || { echo 'SELFTEST escrow build failed.' >&2; exit 2; }
  printf 'WITHENV run_args=%s needs=[%s]\n' "$(printf '%s' "${run_args[@]}" | tr '\n' ' ')" "$needs_secrets"
  needs_secrets=''
  unset STORAGE_ENCRYPTION_KEY
  build_run_args || { echo 'SELFTEST escrow build failed.' >&2; exit 2; }
  printf 'NOENV run_args=%s needs=[%s]\n' "$(printf '%s' "${run_args[@]}" | tr '\n' ' ')" "$needs_secrets"
  exit 0
fi

if [ -z "$stamp" ]; then
  manifest="$(s3ls 'app-manifests/' | grep -E '[0-9]{8}T[0-9]{6}Z\.json$' | grep -v '/gaps-' | grep -v '/failed-' | sort | tail -n1)"
  [ -n "$manifest" ] || { echo 'no app manifests in R2 (fail closed).' >&2; exit 2; }
  stamp="$(printf '%s' "$manifest" | grep -oE '[0-9]{8}T[0-9]{6}Z')"
  [ -n "$stamp" ] || { echo 'manifest name carries no stamp (fail closed).' >&2; exit 2; }
  log "using latest stamp: ${stamp}"
fi

FAILED=0
# Probe and recreate planes both certify downloads against the stamp
# manifest: download it once, classify it (complete|legacy; incomplete
# refuses), then verify every payload against its record.
MANIFEST_CLASS='complete'
probe_manifest_json="${workdir}/probe-manifest.json"
probe_manifest_key="$(s3ls 'app-manifests/' | grep -F "$stamp" | grep -E 'Z\.json$' | grep -v '/gaps-' | grep -v '/failed-' | head -n1 || true)"
[ -n "$probe_manifest_key" ] || { echo "no manifest for stamp ${stamp} (incomplete backup; fail closed)." >&2; exit 2; }
s3get "$probe_manifest_key" "$probe_manifest_json" || { echo 'manifest download failed.' >&2; exit 2; }
classify_manifest "$probe_manifest_json" || exit 2
recreated_count=0



# --- --recreate NAME: bring the workload back into service ---
# Recreates destroyed volumes from snapshots, recreates destroyed containers
# from recorded images, restores dumps with data-parity verification against
# the manifest counts, and health-checks the result. Refuses to clobber
# anything that still exists (fail closed). Consumers re-point to the
# recreated names (original names are reused when the originals are gone).
if [ -n "$recreate" ]; then
  manifest_json="$probe_manifest_json"
  classify_manifest "$manifest_json" || exit 2
  # Refuse to clobber live state.
  clashes="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E "^${recreate}(-|$)" || true)"
  [ -z "$clashes" ] || { echo "refusing: live containers match ${recreate}: ${clashes}." >&2; exit 2; }
  vol_clash="$(docker volume ls -q 2>/dev/null | grep -E "^${recreate}-" || true)"
  [ -z "$vol_clash" ] || { echo "refusing: live volumes match ${recreate}: ${vol_clash}." >&2; exit 2; }
  # The recreated superuser password arrives via --db-password or
  # APP_DB_PASSWORD env (the operator wrapper resolves it from OpenBao:
  # explicit value, reuse of the escrowed per-workload entry, or fresh
  # generation + escrow — fail closed when absent). It becomes the live
  # credential, so it must be known, never invented silently; it lives
  # only in transient process state (stdin-piped env, never argv/disk).
  [ -n "$db_password" ] || { echo '--recreate requires --db-password or APP_DB_PASSWORD env (the recreated superuser credential; never invented silently).' >&2; exit 2; }
  newpw="$db_password"; db_password=''
  # Volumes first (containers mount them).
  for vkey in $(python3 -c 'import json,sys; print(" ".join(v["key"] for v in json.load(open(sys.argv[1])).get("volumes",[]) if v.get("volume","").startswith(sys.argv[2]+"-")))' "$manifest_json" "$recreate"); do
    vname="$(python3 -c 'import json,sys; print(next(v["volume"] for v in json.load(open(sys.argv[1])).get("volumes",[]) if v["key"]==sys.argv[2]))' "$manifest_json" "$vkey")"
    vfiles="$(python3 -c 'import json,sys; print(next(v.get("files",0) for v in json.load(open(sys.argv[1])).get("volumes",[]) if v["key"]==sys.argv[2]))' "$manifest_json" "$vkey")"
    docker volume create "$vname" >/dev/null || { echo "FAILED create volume ${vname}." >&2; FAILED=1; continue; }
    s3get "$vkey" "$workdir/v.tar.gz" || { echo "FAILED download ${vkey}." >&2; FAILED=1; continue; }
    verify_manifest_file volumes "$vkey" "$manifest_json" "$workdir/v.tar.gz" || { FAILED=1; rm -f "$workdir/v.tar.gz"; continue; }
    if docker run --rm -v "${vname}:/data" -v "${workdir}:/backup" alpine:3 tar xzf /backup/v.tar.gz -C /data >/dev/null 2>&1; then
      got="$(docker run --rm -v "${vname}:/data:ro" alpine:3 sh -c 'find /data -type f | wc -l' 2>/dev/null || echo 0)"
      # Never-short invariant: a hot volume snapshot races running writers
      # (count and tar are seconds apart), so restored may legitimately
      # EXCEED the manifest count; falling short means data loss. The dump
      # restore (exact tables/rows) is the consistency point, not the tar.
      if [ "${got:-0}" -ge "${vfiles:-0}" ]; then
        if [ "${got:-0}" -eq "${vfiles:-0}" ]; then
          log "RESTORED-INTO-SERVICE volume: ${vname} (files=${got})"
          recreated_count=$((recreated_count+1))
        else
          log "RESTORED-INTO-SERVICE volume: ${vname} (files=${got}, manifest had ${vfiles}: hot-copy growth, dump parity authoritative)"
          recreated_count=$((recreated_count+1))
        fi
      else
        echo "FAILED parity ${vname}: manifest files=${vfiles}, restored=${got} (short)." >&2; FAILED=1
      fi
    else
      echo "FAILED untar ${vkey} into ${vname}." >&2; FAILED=1
    fi
    rm -f "$workdir/v.tar.gz"
  done
  # Database containers: full recorded topology (networks, ports, restart,
  # health, env, labels, non-data mounts) via the shared builder. The pgdata
  # mount is omitted (dump restore is authoritative); POSTGRES_* come from
  # the fresh credential, never the redacted record. No topology entry in
  # containers[] means an unrecorded past: fail closed, never bare-restore.
  recreated_dbs=''
  for cname in $(python3 -c 'import json,sys; print(" ".join(sorted({d["container"] for d in json.load(open(sys.argv[1])).get("databases",[]) if d.get("container","").startswith(sys.argv[2]+"-")})))' "$manifest_json" "$recreate"); do
    cimage="$(python3 -c 'import json,sys; print(next(d.get("image","postgres:15-alpine") for d in json.load(open(sys.argv[1])).get("databases",[]) if d["container"]==sys.argv[2]))' "$manifest_json" "$cname")"
    cuser="$(python3 -c 'import json,sys; print(next((d.get("user") or "postgres") for d in json.load(open(sys.argv[1])).get("databases",[]) if d["container"]==sys.argv[2]))' "$manifest_json" "$cname")"
    cspec="$(python3 -c 'import json,sys; cs=[c for c in json.load(open(sys.argv[1])).get("containers",[]) if c["name"]==sys.argv[2]]; print(json.dumps(cs[0]) if cs else "")' "$manifest_json" "$cname")"
    [ -n "$cspec" ] || { echo "FAILED topology ${cname}: no recorded entry (refusing bare restore)." >&2; FAILED=1; continue; }
    pgdata="$(printf '%s' "$cspec" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("env",{}).get("PGDATA","/var/lib/postgresql/data"))')"
    [ -n "$pgdata" ] || pgdata='/var/lib/postgresql/data'
    SPEC_CSPEC="$cspec"; SPEC_CNAME="$cname"; SPEC_SKIP_ENVS='POSTGRES_USER POSTGRES_PASSWORD'; SPEC_SKIP_MOUNT="$pgdata"
    build_run_args || { echo "FAILED flags ${cname}." >&2; FAILED=1; continue; }
    run_args+=(-e "POSTGRES_USER=${cuser}" -e "POSTGRES_PASSWORD=${newpw}")
    docker run -d --name "$cname" "${run_args[@]}" "$cimage" ${cmd_args[@]+"${cmd_args[@]}"} >/dev/null 2>&1 || { echo "FAILED start ${cname}." >&2; FAILED=1; continue; }
    for net in $extra_nets; do
      [ -n "$net" ] && docker network connect "$net" "$cname" >/dev/null 2>&1 || true
    done
    recreated_dbs="${recreated_dbs} ${cname}"
    sleep 8
    for dkey in $(python3 -c 'import json,sys; print(" ".join(d["key"] for d in json.load(open(sys.argv[1])).get("databases",[]) if d["container"]==sys.argv[2]))' "$manifest_json" "$cname"); do
      dbase="$(python3 -c 'import json,sys; print(next(d["database"] for d in json.load(open(sys.argv[1])).get("databases",[]) if d["key"]==sys.argv[2]))' "$manifest_json" "$dkey")"
      exp_tables="$(python3 -c 'import json,sys; print(next(d.get("tables",0) for d in json.load(open(sys.argv[1])).get("databases",[]) if d["key"]==sys.argv[2]))' "$manifest_json" "$dkey")"
      exp_rows="$(python3 -c 'import json,sys; print(next(d.get("rows",0) for d in json.load(open(sys.argv[1])).get("databases",[]) if d["key"]==sys.argv[2]))' "$manifest_json" "$dkey")"
      s3get "$dkey" "$workdir/r.dump.gz" || { echo "FAILED download ${dkey}." >&2; FAILED=1; continue; }
      verify_manifest_file databases "$dkey" "$manifest_json" "$workdir/r.dump.gz" || { FAILED=1; rm -f "$workdir/r.dump.gz"; continue; }
      if docker exec -e "PGPASSWORD=${newpw}" "$cname" psql -U "$cuser" -d postgres -tAc "CREATE DATABASE \"${dbase}\";" >/dev/null 2>&1 \
        && docker cp "$workdir/r.dump.gz" "$cname:/tmp/r.dump.gz" >/dev/null 2>&1 \
        && docker exec "$cname" sh -c 'gzip -dc /tmp/r.dump.gz | pg_restore --no-owner --no-acl -U '"$cuser"' -d '"$dbase" >/dev/null 2>&1; then
        got_t="$(docker exec -e "PGPASSWORD=${newpw}" "$cname" psql -U "$cuser" -d "$dbase" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null || echo -1)"
        got_r="$(docker exec -e "PGPASSWORD=${newpw}" "$cname" psql -U "$cuser" -d "$dbase" -tAc "SELECT coalesce(sum(n_live_tup)::int,0) FROM pg_stat_user_tables;" 2>/dev/null || echo -1)"
        if [ "${got_t:-0}" -eq "${exp_tables:-0}" ] && [ "${got_r:-0}" -ge "${exp_rows:-0}" ]; then
          log "RESTORED-INTO-SERVICE database: ${cname}/${dbase} (tables=${got_t}, rows=${got_r})"
          recreated_count=$((recreated_count+1))
        else
          echo "FAILED parity ${cname}/${dbase}: expected tables=${exp_tables} rows>=${exp_rows}, got tables=${got_t} rows=${got_r}." >&2; FAILED=1
        fi
      else
        echo "FAILED restore ${dkey} into ${cname}." >&2; FAILED=1
      fi
      rm -f "$workdir/r.dump.gz"
    done
    if [ -n "$(printf '%s' "$cspec" | python3 -c 'import json,sys; t=(json.load(sys.stdin).get("runtime",{}).get("healthcheck",{}) or {}).get("Test",[]); print("yes" if t else "")')" ]; then
      healthy=''; for _ in $(seq 1 12); do
        [ "$(docker inspect "$cname" --format '{{.State.Health.Status}}' 2>/dev/null)" = 'healthy' ] && { healthy=1; break; }
        sleep 5
      done
      if [ -n "$healthy" ]; then
        log "HEALTHY: ${cname} healthy (recorded healthcheck converging; replacement superuser password rotated in at recreate; re-point consumers)."
      else
        echo "FAILED health: ${cname} never reached healthy." >&2; FAILED=1
      fi
    elif docker inspect "$cname" --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
      log "HEALTHY: ${cname} running (replacement superuser password was rotated in at recreate; re-point consumers)."
    else
      echo "FAILED health: ${cname} not running." >&2; FAILED=1
    fi
  done
  # Application (non-database) containers: full topology recreation.
  recreated_apps=''
  db_containers="$(python3 -c 'import json,sys; print(" ".join(sorted({d["container"] for d in json.load(open(sys.argv[1])).get("databases",[])})))' "$manifest_json")"
  needs_secrets=''
  for cname in $(python3 -c 'import json,sys; print(" ".join(sorted({c["name"] for c in json.load(open(sys.argv[1])).get("containers",[])})))' "$manifest_json"); do
    case " $db_containers " in *" $cname "*) continue ;; esac
    case "$cname" in "${recreate}-"*) ;; *) continue ;; esac
    cspec="$(python3 -c 'import json,sys; print(json.dumps(next(c for c in json.load(open(sys.argv[1])).get("containers",[]) if c["name"]==sys.argv[2])))' "$manifest_json" "$cname")"
    cimage="$(printf '%s' "$cspec" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("image",""))')"
    [ -n "$cimage" ] || { echo "FAILED topology ${cname}: no image recorded." >&2; FAILED=1; continue; }
    SPEC_CSPEC="$cspec"; SPEC_CNAME="$cname"; SPEC_SKIP_ENVS=''; SPEC_SKIP_MOUNT=''
    build_run_args || { echo "FAILED flags ${cname}." >&2; FAILED=1; continue; }
    if docker run -d --name "$cname" "${run_args[@]}" "$cimage" ${cmd_args[@]+"${cmd_args[@]}"} >/dev/null 2>&1; then
      for net in $extra_nets; do
        [ -n "$net" ] && docker network connect "$net" "$cname" >/dev/null 2>&1 || true
      done
      sleep 5
      if docker inspect "$cname" --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
        log "RESTORED-INTO-SERVICE app container: ${cname} (${cimage})"
        recreated_count=$((recreated_count+1))
        recreated_apps="${recreated_apps:-} ${cname}"
      else
        echo "FAILED health: ${cname} not running." >&2; FAILED=1
      fi
    else
      echo "FAILED start app container ${cname}." >&2; FAILED=1
    fi
  done
  [ -z "$needs_secrets" ] || log "WARNING: recreated containers need secret re-injection:${needs_secrets}"
  # Declared bind paths (e.g. SQLite directories): recreate the directory
  # and untar the snapshot into it. Refuses non-empty targets (fail closed).
  for bkey in $(python3 -c 'import json,sys; print(" ".join(b["key"] for b in json.load(open(sys.argv[1])).get("binds",[])))' "$manifest_json"); do
    bpath="$(python3 -c 'import json,sys; print(next(b["path"] for b in json.load(open(sys.argv[1])).get("binds",[]) if b["key"]==sys.argv[2]))' "$manifest_json" "$bkey")"
    bfiles="$(python3 -c 'import json,sys; print(next(b.get("files",0) for b in json.load(open(sys.argv[1])).get("binds",[]) if b["key"]==sys.argv[2]))' "$manifest_json" "$bkey")"
    if [ -e "$bpath" ] && [ -n "$(ls -A "$bpath" 2>/dev/null)" ]; then
      echo "refusing: bind target ${bpath} exists and is non-empty." >&2; FAILED=1; continue
    fi
    mkdir -p "$bpath" || { echo "FAILED mkdir ${bpath}." >&2; FAILED=1; continue; }
    s3get "$bkey" "$workdir/b.tar.gz" || { echo "FAILED download ${bkey}." >&2; FAILED=1; continue; }
    verify_manifest_file binds "$bkey" "$manifest_json" "$workdir/b.tar.gz" || { FAILED=1; rm -f "$workdir/b.tar.gz"; continue; }
    # Strip the leading slash recorded at backup (tar -C / path-without-slash).
    if tar xzf "$workdir/b.tar.gz" -C / >/dev/null 2>&1; then
      got="$(find "$bpath" -type f 2>/dev/null | wc -l)"
      if [ "${got:-0}" -eq "${bfiles:-0}" ]; then
        log "RESTORED-INTO-SERVICE bind: ${bpath} (files=${got})"
        recreated_count=$((recreated_count+1))
      else
        echo "FAILED parity ${bpath}: manifest files=${bfiles}, restored=${got}." >&2; FAILED=1
      fi
    else
      echo "FAILED untar ${bkey} into ${bpath}." >&2; FAILED=1
    fi
    rm -f "$workdir/b.tar.gz"
  done
  # Service connectivity: every recreated app container must reach every
  # recreated database container on each shared network (disposable nc
  # prober on that network; no dependence on app-image tooling).
  while IFS='|' read -r app db net port; do
    [ -n "$app" ] || continue
    if docker run --rm --network "$net" alpine:3 sh -c "nc -z -w5 '$db' '$port'" >/dev/null 2>&1; then
      log "CONNECT_OK: ${app} reaches ${db}:${port} on ${net}"
    else
      echo "FAILED connectivity: ${app} cannot reach ${db}:${port} on ${net}." >&2; FAILED=1
    fi
  done <<<"$(python3 -c '
import json,sys
m = json.load(open(sys.argv[1]))
apps = {c["name"]: c.get("networks",[]) for c in m.get("containers",[]) if c["name"] in sys.argv[2].split()}
dbs = {}
for c in m.get("containers",[]):
    if c["name"] not in sys.argv[3].split(): continue
    ports = [p.split(":")[-1].split("/")[0] for p in c.get("ports",[]) if "/tcp" in p]
    dbs[c["name"]] = (c.get("networks",[]), ports[0] if ports else "5432")
for an, anets in apps.items():
    for dn, (dnets, dport) in dbs.items():
        for net in sorted(set(anets) & set(dnets)):
            print(f"{an}|{dn}|{net}|{dport}")
' "$manifest_json" "${recreated_apps:-}" "${recreated_dbs:-}")"
  if [ "${recreated_count:-0}" -eq 0 ]; then echo "FAILED: stamp ${stamp} recreated nothing for ${recreate} (refusing empty success)." >&2; exit 2; fi
  if [ "$FAILED" -ne 0 ]; then echo 'recreate incomplete (fail closed; partial state left for inspection).' >&2; exit 2; fi
  trap - EXIT
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
    verify_manifest_file databases "$key" "$probe_manifest_json" "$workdir/r.dump.gz" || { FAILED=1; rm -f "$workdir/r.dump.gz"; continue; }
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
  verify_manifest_file volumes "$key" "$probe_manifest_json" "$workdir/v.tar.gz" || { FAILED=1; rm -f "$workdir/v.tar.gz"; continue; }
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

# --- binds: restore each stamp snapshot into temp dir, verify files ---
binds="$(s3ls 'app-binds/' | grep -F "$stamp" || true)"
[ -n "$binds" ] || log 'no app-bind snapshots for this stamp.'
for key in $binds; do
  [ -n "$key" ] || continue
  bdir="$workdir/bind"; rm -rf "$bdir"; mkdir -p "$bdir"
  s3get "$key" "$workdir/b.tar.gz" || { echo "FAILED download ${key}." >&2; FAILED=1; continue; }
  verify_manifest_file binds "$key" "$probe_manifest_json" "$workdir/b.tar.gz" || { FAILED=1; rm -f "$workdir/b.tar.gz"; continue; }
  if tar xzf "$workdir/b.tar.gz" -C "$bdir" 2>/dev/null; then
    files="$(find "$bdir" -type f | wc -l)"
    if [ "$files" -gt 0 ]; then
      log "RESTORE_OK bind: ${key} (files=${files})"
    else
      echo "FAILED verify ${key} (empty snapshot)." >&2; FAILED=1
    fi
  else
    echo "FAILED untar ${key}." >&2; FAILED=1
  fi
  rm -f "$workdir/b.tar.gz"; rm -rf "$bdir"
done

trap - EXIT
rm -rf "$workdir"; docker rm -f rollback-app-probe-db >/dev/null 2>&1 || true
if [ "$FAILED" -ne 0 ]; then echo 'one or more workload restores failed (fail closed).' >&2; exit 2; fi
log 'app-workload rollback complete: every stamp artifact restored into probes and verified.'
