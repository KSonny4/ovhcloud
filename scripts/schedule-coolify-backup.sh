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
#   bash scripts/schedule-coolify-backup.sh [--env-file PATH] [--dry-run]
set -euo pipefail

dry_run=0
env_file='/root/coolify-backup/r2.env'
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --env-file) env_file="$2"; shift 2 ;;
    --env-file=*) env_file="${1#--env-file=}"; shift ;;
    -h|--help) echo 'usage: schedule-coolify-backup.sh [--env-file PATH] [--dry-run]'; exit 0 ;;
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
  echo 'must run as root (installs timer + reads the root-only env file).' >&2
  exit 2
fi

if [ ! -f "$env_file" ] && [ "$dry_run" -eq 0 ]; then
  echo "R2 env file not found: ${env_file} (provision it from OpenBao secret/projects/ovhcloud/COOLIFY_R2, mode 0600)." >&2
  exit 2
fi

# shellcheck disable=SC1090
if [ "$dry_run" -eq 0 ]; then
  # shellcheck source=/dev/null
  source "$env_file"
  for v in R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET; do
    if [ -z "${!v:-}" ]; then echo "missing ${v} in ${env_file}." >&2; exit 2; fi
  done
  export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
  export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
fi

if ! command -v aws >/dev/null 2>&1; then
  log 'installing awscli for the S3-compatible R2 upload'
  run apt-get update -qq
  run apt-get install -y -qq awscli
fi
if ! command -v docker >/dev/null 2>&1 && [ "$dry_run" -eq 0 ]; then
  echo 'docker not found on this host; cannot dump coolify-db.' >&2
  exit 2
fi

backup_dir='/root/coolify-backup'
backup_script="${backup_dir}/backup-to-r2.sh"
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
elif [ ! -f "${backup_dir}/backup-app-workloads.sh" ] && [ "$dry_run" -eq 0 ]; then
  echo 'backup-app-workloads.sh found neither beside this script nor installed; refusing to schedule a partial backup.' >&2
  exit 2
fi

cat >"$backup_script" <<'BACKUP_EOF'
#!/usr/bin/env bash
# Nightly Coolify instance DB backup. Sources its credential env file so it
# works both under systemd (EnvironmentFile) and when run by hand.
set -euo pipefail
# shellcheck source=/dev/null
source "@@ENV_FILE@@"
: "${R2_ENDPOINT:?}"; : "${R2_BUCKET:?}"
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
run sed -i "s|@@ENV_FILE@@|${env_file}|" "$backup_script"
run chmod 700 "$backup_script"

# The application-workload script must sit beside the instance script (the
# runner/live operator scp's it there); the unit runs both sequentially and
# fails if either fails.
cat >/etc/systemd/system/coolify-backup.service <<SERVICE_EOF
[Unit]
Description=Nightly Coolify instance + application workload backup to R2
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
EnvironmentFile=${env_file}
ExecStart=${backup_script}
ExecStart=/root/coolify-backup/backup-app-workloads.sh
SERVICE_EOF

cat >/etc/systemd/system/coolify-backup.timer <<'TIMER_EOF'
[Unit]
Description=Run Coolify R2 backup daily at 02:00 UTC

[Timer]
OnCalendar=*-*-* 02:00:00 UTC
Persistent=true

[Install]
WantedBy=timers.target
TIMER_EOF

run systemctl daemon-reload
run systemctl enable --now coolify-backup.timer
log 'timer enabled: coolify-backup.timer (daily 02:00 UTC)'

# First backup now (proves the schedule works end to end).
# shellcheck source=/dev/null
source "$env_file"
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
bash "$backup_script"
log 'schedule live: first backup completed and verified in R2; retention 14 days.'
