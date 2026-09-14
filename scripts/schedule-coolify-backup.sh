#!/usr/bin/env bash
# Nightly Coolify instance-database backup to Cloudflare R2.
#
# Contract:
# - Runs as root ON the target host (preserved VPS or a fresh provision).
# - R2 credentials arrive via an env file (0600, root-only) provisioned from
#   OpenBao by the orchestrator; this script never prints secret values.
# - Installs: awscli (if missing), /root/coolify-backup/backup-to-r2.sh,
#   a systemd oneshot service + daily timer (02:00 UTC), 14-day retention.
# - Runs the first backup immediately and verifies the object in R2.
# - Coolify-native per-database/per-volume schedules attach later to the
#   registered S3 storage once application databases exist (none yet on a
#   fresh install); this host-level job protects the instance DB itself.
#
# Usage (on the host, as root):
#   bash scripts/schedule-coolify-backup.sh [--env-file PATH] [--dry-run] [--install-only]
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
    -h|--help) echo 'usage: schedule-coolify-backup.sh [--env-file PATH] [--dry-run] [--install-only]'; exit 0 ;;
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

# No credential file is required anymore: the timer execs through
# fetch-r2-env.sh (memory-only OpenBao pull). The --env-file flag remains
# only for legacy hosts during migration.

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
if ! command -v docker >/dev/null 2>&1 && [ "$dry_run" -eq 0 ]; then
  echo 'docker not found on this host; cannot dump coolify-db.' >&2
  exit 2
fi

backup_dir="${BACKUP_DIR:-/root/coolify-backup}"
systemd_dir="${SYSTEMD_DIR:-/etc/systemd/system}"
backup_script="${backup_dir}/backup-to-r2.sh"
app_installed="${backup_dir}/backup-app-workloads.sh"
log "backup dir: ${backup_dir}"

if [ "$dry_run" -eq 1 ]; then
  log "DRY-RUN: write ${backup_script} (pg_dump -Fc coolify-db | gzip -> R2 dated key, prune keys older than 14 days)"
  log 'DRY-RUN: install coolify-backup.service + coolify-backup.timer (daily 02:00 UTC, Persistent=true)'
  log 'DRY-RUN: systemctl daemon-reload, enable --now coolify-backup.timer'
  log 'DRY-RUN: run first backup now and verify with s3api head-object'
  exit 0
fi

run mkdir -p "$backup_dir"
run chmod 700 "$backup_dir"

# The application-workload companion must live beside the instance script:
# install it from alongside this script when present, keep the existing copy
# when already deployed, fail closed when found nowhere.
app_src="$(cd "$(dirname "$0")" && pwd)/backup-app-workloads.sh"
if [ -f "$app_src" ]; then
  run cp "$app_src" "${backup_dir}/backup-app-workloads.sh"
  run chmod 700 "${backup_dir}/backup-app-workloads.sh"
  log 'installed application-workload companion script.'
elif [ ! -f "$app_installed" ] && [ "$dry_run" -eq 0 ]; then
  echo 'backup-app-workloads.sh found neither beside this script nor installed; refusing to schedule a partial backup.' >&2
  exit 2
fi

cat >"$backup_script" <<'BACKUP_EOF'
#!/usr/bin/env bash
# Nightly Coolify instance DB backup. Credentials arrive via environment from
# fetch-r2-env.sh (memory-only OpenBao pull); a legacy root-only env file is
# honored only as a fallback and must not exist on new installs.
set -euo pipefail
if [ -z "${R2_ACCESS_KEY_ID:-}" ] && [ -n "${R2_ENV_FILE:-}" ] && [ -f "$R2_ENV_FILE" ]; then
  # shellcheck source=/dev/null
  source "$R2_ENV_FILE"
fi
: "${R2_ENDPOINT:?R2 credentials required via environment (fetch-r2-env.sh)}"; : "${R2_BUCKET:?}"
export AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:?}" AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:?}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
key="coolify-db-${stamp}.dump.gz"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
docker exec coolify-db pg_dump -Fc -U coolify coolify | gzip >"$tmp"
aws --endpoint-url "$R2_ENDPOINT" s3api put-object --bucket "$R2_BUCKET" --key "$key" --body "$tmp" >/dev/null
aws --endpoint-url "$R2_ENDPOINT" s3api head-object --bucket "$R2_BUCKET" --key "$key" >/dev/null
cutoff="$(date -u -d '14 days ago' +%Y%m%d)"
old="$(aws --endpoint-url "$R2_ENDPOINT" s3 ls "s3://${R2_BUCKET}/coolify-db-" 2>/dev/null | awk '{print $4}')"
for k in $old; do
  day="$(printf '%s' "$k" | sed -E 's/coolify-db-([0-9]{8})T.*/\1/')"
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

# The application-workload script must sit beside the instance script (the
# runner/live operator scp's it there); the unit runs both sequentially and
# fails if either fails.
cat >"${systemd_dir}/coolify-backup.service" <<SERVICE_EOF
[Unit]
Description=Nightly Coolify instance + application workload backup to R2
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=${backup_dir}/fetch-r2-env.sh -- ${backup_script}
ExecStart=${backup_dir}/fetch-r2-env.sh -- ${app_installed}
SERVICE_EOF

cat >"${systemd_dir}/coolify-backup.timer" <<'TIMER_EOF'
[Unit]
Description=Run Coolify R2 backup daily at 02:00 UTC

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
    systemd-analyze verify "${systemd_dir}/coolify-backup.service" \
      && log 'unit verified: coolify-backup.service parses (isolated prefix, host systemd untouched).'
  else
    log 'systemd-analyze unavailable; unit content asserted by the caller (host systemd untouched).'
  fi
else
  run systemctl daemon-reload
  run systemctl enable --now coolify-backup.timer
  log 'timer enabled: coolify-backup.timer (daily 02:00 UTC)'
fi

if [ "$install_only" -eq 1 ]; then
  log 'install-only: skipping the immediate first-backup run by request.'
  exit 0
fi

# First backup now through the fetch wrapper (proves the memory-only path
# end to end; the accessor token file must already be provisioned).
bash "${backup_dir}/fetch-r2-env.sh" -- bash "$backup_script"
log 'schedule live: first backup completed and verified in R2; retention 14 days.'
