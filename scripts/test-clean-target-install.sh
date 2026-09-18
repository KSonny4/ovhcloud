#!/usr/bin/env bash
# Clean-target non-dry-run test: proves the backup installer deploys BOTH
# backup commands (cluster snapshot + application workloads) without touching
# production paths or host systemd.
#
# Mirrors exactly what the remote runner ships (schedule-host-backup.sh +
# backup-app-workloads.sh side by side), then runs the installer NON-dry-run
# into an isolated prefix (BACKUP_DIR/SYSTEMD_DIR overrides) with
# --install-only, and asserts every artifact. Cleans up on every exit path.
#
# Runs ON a Linux target as root (or via the preserved host over SSH):
#   bash scripts/test-clean-target-install.sh [--host user@target --ssh-key PATH]
# With --host, the test executes remotely inside /tmp (production untouched).
set -euo pipefail

host='' ssh_key=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --host) host="$2"; shift 2 ;;
    --host=*) host="${1#--host=}"; shift ;;
    --ssh-key) ssh_key="$2"; shift 2 ;;
    --ssh-key=*) ssh_key="${1#--ssh-key=}"; shift ;;
    --local-dir) local_dir="$2"; shift 2 ;;
    --local-dir=*) local_dir="${1#--local-dir=}"; shift ;;
    -h|--help) echo 'usage: test-clean-target-install.sh [--host user@target --ssh-key PATH]'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
if [ -n "$host" ]; then
  ssh_opts=(-o BatchMode=yes -o ConnectTimeout=15)
  [ -n "$ssh_key" ] && ssh_opts=(-i "$ssh_key" "${ssh_opts[@]}")
  remote_stage="/tmp/clean-target-test-$$"
  # shellcheck disable=SC2029
  ssh "${ssh_opts[@]}" "$host" "mkdir -p $remote_stage"
  scp "${ssh_opts[@]}" "$repo_root/scripts/schedule-host-backup.sh" \
    "$repo_root/scripts/backup-app-workloads.sh" \
    "$repo_root/scripts/fetch-r2-env.sh" \
    "$repo_root/scripts/rollback-nomad-snapshot.sh" \
    "$repo_root/scripts/rollback-app-workloads.sh" "$0" "$host:$remote_stage/"
  # shellcheck disable=SC2029
  ssh "${ssh_opts[@]}" "$host" "sudo bash $remote_stage/test-clean-target-install.sh --local-dir $remote_stage"
  rc=$?
  # Client-side expansion is intended: remote_stage is a locally generated
  # /tmp/clean-target-test-PID path, never operator input.
  # shellcheck disable=SC2029
  ssh "${ssh_opts[@]}" "$host" "sudo rm -rf $remote_stage" || true
  exit $rc
fi

# --- on-target execution (local or remote) ---
stage_dir="${local_dir:-}"
[ -n "$stage_dir" ] || stage_dir="$(cd "$(dirname "$0")" && pwd)"
if [ "$(id -u)" -ne 0 ]; then echo 'must run as root.' >&2; exit 2; fi

prefix="$(mktemp -d /tmp/clean-target-install.XXXXXX)"
trap 'rm -rf "$prefix"' EXIT
export BACKUP_DIR="$prefix/backup" SYSTEMD_DIR="$prefix/systemd"
mkdir -p "$SYSTEMD_DIR"
# No credential file: the installer is fileless (fetch wrapper pulls per run).

fail=0
check() { if [ "$1" -ne 0 ]; then echo "FAIL: $2" >&2; fail=1; else echo "ok: $2"; fi; }

bash "${stage_dir}/schedule-host-backup.sh" --install-only >/dev/null 2>&1
check $? 'installer exits 0 non-dry-run into isolated prefix'
[ -x "$BACKUP_DIR/backup-to-r2.sh" ]; check $? 'instance backup script installed executable'
[ -x "$BACKUP_DIR/backup-app-workloads.sh" ]; check $? 'workload companion installed executable'
[ -x "$BACKUP_DIR/fetch-r2-env.sh" ]; check $? 'fetch wrapper installed executable'
[ -x "$BACKUP_DIR/rollback-nomad-snapshot.sh" ]; check $? 'snapshot rollback installed executable'
[ -x "$BACKUP_DIR/rollback-app-workloads.sh" ]; check $? 'workload rollback installed executable'
if grep -q 'EnvironmentFile' "$SYSTEMD_DIR/host-backup.service" 2>/dev/null; then echo 'FAIL: unit still references EnvironmentFile' >&2; fail=1; else echo 'ok: unit carries no EnvironmentFile (memory-only)'; fi
if grep -q 'fetch-r2-env.sh -- ' "$SYSTEMD_DIR/host-backup.service" 2>/dev/null; then echo 'ok: unit execs through fetch wrapper'; else echo 'FAIL: unit bypasses fetch wrapper' >&2; fail=1; fi
grep -q "fetch-r2-env.sh -- ${BACKUP_DIR}/backup-to-r2.sh" "$SYSTEMD_DIR/host-backup.service" 2>/dev/null; check $? 'unit carries instance ExecStart via wrapper'
grep -q "fetch-r2-env.sh -- ${BACKUP_DIR}/backup-app-workloads.sh" "$SYSTEMD_DIR/host-backup.service" 2>/dev/null; check $? 'unit carries workload ExecStart via wrapper'
[ -f "$SYSTEMD_DIR/host-backup.timer" ]; check $? 'timer unit installed'
if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze verify "$SYSTEMD_DIR/host-backup.service" >/dev/null 2>&1; check $? 'systemd-analyze verify passes'
fi

trap - EXIT
rm -rf "$prefix"
if [ "$fail" -eq 0 ]; then
  echo 'CLEAN-TARGET INSTALL TEST: PASS'
else
  echo 'CLEAN-TARGET INSTALL TEST: FAIL' >&2
  exit 1
fi
