#!/usr/bin/env bash
# R2 backup verification probe for the OVHcloud/Coolify redesign.
#
# Contract:
# - Bucket itself is owned by Terraform (cloudflare_r2_bucket.backups).
# - Scoped R2 credentials are generated out-of-band and escrowed in OpenBao at
#   secret/projects/ovhcloud/COOLIFY_R2 (access_key_id, secret_access_key, bucket).
# - This script never prints secret values; it reports redacted status only.
# - Proves write/read/delete on a disposable probe object, then reports the
#   retention/rollback expectations for Coolify and OVH layers.
#
# Usage:
#   R2_ENDPOINT='https://<account>.r2.cloudflarestorage.com' \
#   R2_BUCKET='ovh-coolify-backups' \
#   AWS_ACCESS_KEY_ID='<from OpenBao>' AWS_SECRET_ACCESS_KEY='<from OpenBao>' \
#   bash scripts/backup-r2-probe.sh [--dry-run]
set -euo pipefail

dry_run=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    -h|--help) echo 'usage: backup-r2-probe.sh [--dry-run]'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
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

endpoint="${R2_ENDPOINT:-}"
bucket="${R2_BUCKET:-ovh-coolify-backups}"
# R2's S3 API requires a region matching the bucket jurisdiction (ours is
# EEUR); `auto` negotiates it and works for every jurisdiction.
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
if [ -z "$endpoint" ] && [ "$dry_run" -eq 0 ]; then
  echo 'R2_ENDPOINT must be set (S3-compatible endpoint, value is not secret).' >&2
  exit 2
fi
if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  if [ "$dry_run" -eq 1 ]; then
    log 'DRY-RUN: read scoped R2 credentials from OpenBao-backed environment (values not printed)'
  else
    echo 'AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must come from OpenBao.' >&2
    exit 2
  fi
fi

probe_object="rehearsal-probe-$(date -u +%Y%m%dT%H%M%SZ).txt"
log "bucket: ${bucket}"
log "endpoint: ${endpoint:-dry-run}"
log "probe object: ${probe_object}"

if ! command -v aws >/dev/null 2>&1; then
  if [ "$dry_run" -eq 1 ]; then
    log 'DRY-RUN: require awscli for the S3-compatible probe'
  else
    echo 'awscli is required for the R2 probe.' >&2
    exit 2
  fi
fi

if [ "$dry_run" -eq 1 ]; then
  log 'DRY-RUN: aws s3api put-object (probe payload, no real credentials)'
  log 'DRY-RUN: aws s3api head-object (probe exists and is non-zero)'
  log 'DRY-RUN: aws s3api get-object (restore probe returns probe payload)'
  log 'DRY-RUN: aws s3api delete-object (probe cleaned up)'
else
  payload="$(mktemp)"
  downloaded="$(mktemp)"
  trap 'rm -f "$payload" "$downloaded"' EXIT
  printf 'ovh-coolify backup probe %s\n' "$(date -u +%FT%TZ)" >"$payload"
  run aws --endpoint-url "$endpoint" s3api put-object --bucket "$bucket" --key "$probe_object" --body "$payload" >/dev/null
  run aws --endpoint-url "$endpoint" s3api head-object --bucket "$bucket" --key "$probe_object" >/dev/null
  run aws --endpoint-url "$endpoint" s3api get-object --bucket "$bucket" --key "$probe_object" "$downloaded" >/dev/null
  if ! cmp -s "$payload" "$downloaded"; then
    echo 'restore probe mismatch: downloaded object differs.' >&2
    exit 1
  fi
  run aws --endpoint-url "$endpoint" s3api delete-object --bucket "$bucket" --key "$probe_object" >/dev/null
  trap - EXIT
  rm -f "$payload" "$downloaded"
  log 'probe ok: write/head/restore/delete succeeded; probe object removed.'
fi

cat <<'EOF'
retention/rollback expectations (enforced by runbook + Coolify schedule, verified by rehearsal):
- Coolify instance database backup: daily to R2, retain >= 14 days.
- Application databases/volumes: daily or better to R2, retain 14-30 days.
- Whole-VPS safety net: OVH Automated Backup enabled daily.
- Pre-change rollback: OVH snapshot before risky changes (one active at a time).
- Recovery requires the escrowed Coolify APP_KEY plus the R2 credential in OpenBao.
EOF
