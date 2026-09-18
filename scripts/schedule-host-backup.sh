#!/usr/bin/env bash
# Nightly Nomad snapshot backup to Cloudflare R2.
#
# Contract:
# - Runs as root ON the target host (preserved VPS or a fresh provision).
# - R2 credentials AND the Nomad ACL token are memory-only: the timer execs
#   every backup through fetch-r2-env.sh (OpenBao pull per run); no
#   credential file is used, ever. This script never prints secret values.
# - Installs: awscli + bao CLI (if missing), /root/host-backup/ scripts
#   (snapshot backup, workload backup, fetch wrapper, both rollback
#   procedures — a rollback-less schedule is refused),
#   a systemd oneshot service + daily timer (02:00 UTC), 14-day retention.
# - Runs the first backup immediately and verifies the object in R2.
#
# Usage (on the host, as root):
#   bash scripts/schedule-host-backup.sh [--dry-run] [--install-only]
#
# Testability: BACKUP_DIR and SYSTEMD_DIR override the install prefixes so a
# clean-target test can run the NON-dry-run installer into an isolated prefix
# (production paths untouched, host systemd untouched). --install-only skips
# the immediate first-backup run (used by the clean-target test; the live
# path always runs it).
set -euo pipefail

dry_run=0
install_only=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --install-only) install_only=1; shift ;;
    -h|--help) echo 'usage: schedule-host-backup.sh [--dry-run] [--install-only]'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() { printf '%s\n' "$*"; }
run() {
  if [ "$dry_run" -eq 1 ]; then
    log "DRY-RUN: $*"
  else
    "$@"
  fi
}

if [ "$(id -u)" -ne 0 ] && [ "$dry_run" -eq 0 ]; then
  echo 'must run as root (installs timer + backup scripts).' >&2
  exit 2
fi

# No credential file is used, ever: the timer execs through fetch-r2-env.sh
# (memory-only OpenBao pull).

if ! command -v aws >/dev/null 2>&1; then
  log 'installing awscli for the S3-compatible R2 upload'
  run apt-get update -qq
  run apt-get install -y -qq awscli
fi
if ! command -v bao >/dev/null 2>&1 && [ "$dry_run" -eq 0 ]; then
  log 'installing bao CLI (OpenBao memory-only credential delivery)'
  bao_deb="$(curl -fsSL https://api.github.com/repos/openbao/openbao/releases/latest | python3 -c 'import json,sys; print([a["browser_download_url"] for a in json.load(sys.stdin)["assets"] if a["name"].startswith("openbao_") and a["name"].endswith("linux_amd64.deb") and "-hsm" not in a["name"]][0])')"
  run curl -fsSL -o /tmp/openbao.deb "$bao_deb"
  run dpkg -i /tmp/openbao.deb
  run rm -f /tmp/openbao.deb
  bao version >/dev/null || { echo 'bao install verification failed.' >&2; exit 2; }
fi
if ! command -v nomad >/dev/null 2>&1 && [ "$dry_run" -eq 0 ]; then
  echo 'nomad not found on this host; cannot snapshot cluster state.' >&2
  exit 2
fi

backup_dir="${BACKUP_DIR:-/root/host-backup}"
systemd_dir="${SYSTEMD_DIR:-/etc/systemd/system}"
backup_script="${backup_dir}/backup-to-r2.sh"
app_installed="${backup_dir}/backup-app-workloads.sh"
log "backup dir: ${backup_dir}"

if [ "$dry_run" -eq 1 ]; then
  log "DRY-RUN: write ${backup_script} (nomad snapshot save -> R2 dated key, prune keys older than 14 days)"
  log 'DRY-RUN: install host-backup.service + host-backup.timer (daily 02:00 UTC, Persistent=true)'
  log 'DRY-RUN: systemctl daemon-reload, enable --now host-backup.timer'
  log 'DRY-RUN: run first backup now and verify with s3api head-object'
  exit 0
fi

run mkdir -p "$backup_dir"
run chmod 700 "$backup_dir"

# The application-workload companion must live beside the snapshot script:
# install it from alongside this script when present, keep the existing copy
# when already deployed, fail closed when found nowhere.
app_src="$(cd "$(dirname "$0")" && pwd)/backup-app-workloads.sh"
allow_src="$(cd "$(dirname "$0")" && pwd)/lib/escrowed-app-envs"
[ -f "$allow_src" ] || allow_src="$(cd "$(dirname "$0")" && pwd)/escrowed-app-envs"
if [ -f "$app_src" ]; then
  run cp "$app_src" "${backup_dir}/backup-app-workloads.sh"
  run chmod 700 "${backup_dir}/backup-app-workloads.sh"
  log 'installed application-workload companion script.'
  # Escrow allowlist (names only, non-secret) travels with the backup
  # companion so manifests mark escrow-recoverable env for relay-free
  # restore; absent file = all redactions operator-relayed (safe default).
  if [ -f "$allow_src" ]; then
    run cp "$allow_src" "${backup_dir}/escrowed-app-envs"
    run chmod 600 "${backup_dir}/escrowed-app-envs"
    log 'installed escrow allowlist (names only).'
  else
    log 'WARNING: escrow allowlist not shipped; redactions stay operator-relayed.'
  fi
elif [ ! -f "$app_installed" ] && [ "$dry_run" -eq 0 ]; then
  echo 'backup-app-workloads.sh found neither beside this script nor installed; refusing to schedule a partial backup.' >&2
  exit 2
fi

# Rollback procedures ship with the schedule (fresh targets must be able to
# roll back noninteractively): same install-or-fail-closed companion pattern.
for rollback_src in rollback-nomad-snapshot.sh rollback-app-workloads.sh; do
  src_path="$(cd "$(dirname "$0")" && pwd)/${rollback_src}"
  if [ -f "$src_path" ]; then
    run cp "$src_path" "${backup_dir}/${rollback_src}"
    run chmod 700 "${backup_dir}/${rollback_src}"
    log "installed ${rollback_src}."
  elif [ ! -f "${backup_dir}/${rollback_src}" ] && [ "$dry_run" -eq 0 ]; then
    echo "${rollback_src} found neither beside this script nor installed; refusing a rollback-less schedule." >&2
    exit 2
  fi
done

cat >"$backup_script" <<'BACKUP_EOF'
#!/usr/bin/env bash
# Nightly Nomad snapshot backup. Credentials arrive ONLY via environment
# from fetch-r2-env.sh (memory-only OpenBao pull). No credential file.
set -euo pipefail
: "${R2_ENDPOINT:?R2 credentials required via environment (fetch-r2-env.sh)}"; : "${R2_BUCKET:?}"
: "${NOMAD_TOKEN:?Nomad ACL token required via environment (fetch-r2-env.sh)}"
export AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:?}" AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:?}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
export NOMAD_ADDR="${NOMAD_ADDR:-http://127.0.0.1:4646}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
key="nomad-snapshot-${stamp}.snap"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
nomad operator snapshot save "$tmp"
aws --endpoint-url "$R2_ENDPOINT" s3api put-object --bucket "$R2_BUCKET" --key "$key" --body "$tmp" >/dev/null
aws --endpoint-url "$R2_ENDPOINT" s3api head-object --bucket "$R2_BUCKET" --key "$key" >/dev/null
cutoff="$(date -u -d '14 days ago' +%Y%m%d)"
old="$(aws --endpoint-url "$R2_ENDPOINT" s3 ls "s3://${R2_BUCKET}/nomad-snapshot-" 2>/dev/null | awk '{print $4}')"
for k in $old; do
  day="$(printf '%s' "$k" | sed -E 's/nomad-snapshot-([0-9]{8})T.*/\1/')"
  if [ "$day" \< "$cutoff" ]; then
    aws --endpoint-url "$R2_ENDPOINT" s3api delete-object --bucket "$R2_BUCKET" --key "$k" >/dev/null
    echo "pruned ${k} (older than 14 days)"
  fi
done
trap - EXIT
rm -f "$tmp"
echo "backup ok: ${key}"
BACKUP_EOF
run chmod 700 "$backup_script"

# The OpenBao fetch wrapper must live beside the backup scripts; the unit
# execs through it so R2 keys stay memory-only. Same fail-closed companion
# pattern as backup-app-workloads.sh.
fetch_src="$(cd "$(dirname "$0")" && pwd)/fetch-r2-env.sh"
if [ -f "$fetch_src" ]; then
  run cp "$fetch_src" "${backup_dir}/fetch-r2-env.sh"
  run chmod 700 "${backup_dir}/fetch-r2-env.sh"
  log 'installed OpenBao fetch wrapper.'
elif [ ! -f "${backup_dir}/fetch-r2-env.sh" ] && [ "$dry_run" -eq 0 ]; then
  echo 'fetch-r2-env.sh found neither beside this script nor installed; refusing to schedule fileless backup.' >&2
  exit 2
fi

# The snapshot script must sit beside the workload script (the
# runner/live operator scp's it there); the unit runs both sequentially and
# fails if either fails.
cat >"${systemd_dir}/host-backup.service" <<SERVICE_EOF
[Unit]
Description=Nightly Nomad snapshot + application workload backup to R2
Wants=network-online.target
After=network-online.target docker.service nomad.service

[Service]
Type=oneshot
ExecStart=${backup_dir}/fetch-r2-env.sh -- ${backup_script}
ExecStart=${backup_dir}/fetch-r2-env.sh -- ${app_installed}
SERVICE_EOF

cat >"${systemd_dir}/host-backup.timer" <<'TIMER_EOF'
[Unit]
Description=Run Nomad R2 backup daily at 02:00 UTC

[Timer]
OnCalendar=*-*-* 02:00:00 UTC
Persistent=true

[Install]
WantedBy=timers.target
TIMER_EOF

# An overridden SYSTEMD_DIR means an isolated clean-target test: verify the
# unit files parse instead of touching host systemd.
if [ "$systemd_dir" != '/etc/systemd/system' ]; then
  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify "${systemd_dir}/host-backup.service" \
      && log 'unit verified: host-backup.service parses (isolated prefix, host systemd untouched).'
  else
    log 'systemd-analyze unavailable; unit content asserted by the caller (host systemd untouched).'
  fi
else
  run systemctl daemon-reload
  run systemctl enable --now host-backup.timer
  log 'timer enabled: host-backup.timer (daily 02:00 UTC)'
fi

if [ "$install_only" -eq 1 ]; then
  log 'install-only: skipping the immediate first-backup run by request.'
  exit 0
fi

# First backup now through the fetch wrapper (proves the memory-only path
# end to end; the accessor token file must already be provisioned).
bash "${backup_dir}/fetch-r2-env.sh" -- bash "$backup_script"
log 'schedule live: first backup completed and verified in R2; retention 14 days.'
