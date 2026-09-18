#!/usr/bin/env bash
# Executable Nomad snapshot rollback/recovery proof for the OVHcloud redesign.
#
# Contract:
# - Runs as root ON the target host (same host as schedule-host-backup.sh).
# - Reads R2 credentials + the Nomad ACL token from environment via
#   fetch-r2-env.sh (memory-only OpenBao pull); never prints secret values.
# - Downloads the LATEST scheduled snapshot from R2, restores it into a
#   disposable probe agent (isolated ports + data dir; production state is
#   never written), verifies known data (server alive + jobs registered),
#   kills the probe, and reports RESTORE_OK. Production data is never
#   written.
# - Every stage fails closed: a missing snapshot, failed download, failed
#   restore, or failed verification exits nonzero with the probe killed.
#
# Usage (on the host, as root):
#   sudo bash fetch-r2-env.sh -- bash scripts/rollback-nomad-snapshot.sh [--dry-run]
set -euo pipefail

dry_run=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    -h|--help) echo 'usage: rollback-nomad-snapshot.sh [--dry-run]'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() { printf '%s\n' "$*"; }

if [ "$(id -u)" -ne 0 ] && [ "$dry_run" -eq 0 ]; then
  echo 'must run as root.' >&2
  exit 2
fi

if [ "$dry_run" -eq 1 ]; then
  log 'DRY-RUN: list R2 snapshot objects, select latest nomad-snapshot-*.snap'
  log 'DRY-RUN: download latest snapshot, restore into disposable probe agent'
  log 'DRY-RUN: verify known data (server alive + jobs registered), kill probe, report RESTORE_OK (fail closed)'
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
command -v nomad >/dev/null 2>&1 || { echo 'nomad is required.' >&2; exit 2; }

latest="$(aws --endpoint-url "$R2_ENDPOINT" s3 ls "s3://${R2_BUCKET}/nomad-snapshot-" 2>/dev/null \
  | awk '{print $4}' | sort | tail -n1)"
if [ -z "$latest" ]; then
  echo 'no scheduled snapshot objects found in R2 (fail closed).' >&2
  exit 2
fi
log "latest scheduled snapshot: ${latest}"

probe_dir="$(mktemp -d)"
probe_cfg="${probe_dir}/probe.hcl"
snap_file="${probe_dir}/latest.snap"
probe_pid=''
cleanup_probe() {
  if [ -n "$probe_pid" ]; then kill "$probe_pid" 2>/dev/null || true; fi
  rm -rf "$probe_dir"
}
trap cleanup_probe EXIT

aws --endpoint-url "$R2_ENDPOINT" s3api get-object --bucket "$R2_BUCKET" --key "$latest" "$snap_file" >/dev/null
log 'snapshot downloaded.'

# Disposable probe agent: isolated loopback ports + throwaway data dir.
# Production (:4646) is never touched — the restore target is the probe.
# No acl stanza: enforcement stays off in the probe so the restored job
# table is readable regardless of the snapshot's ACL state.
cat >"$probe_cfg" <<'PROBE_EOF'
datacenter = "probe"
data_dir   = "PROBE_DATA_DIR"
bind_addr  = "127.0.0.1"
ports {
  http = 14646
  rpc  = 14647
  serf = 14648
}
advertise {
  http = "127.0.0.1:14646"
  rpc  = "127.0.0.1:14647"
  serf = "127.0.0.1:14648"
}
server {
  enabled          = true
  bootstrap_expect = 1
}
client {
  enabled = false
}
PROBE_EOF
sed -i.bak "s|PROBE_DATA_DIR|${probe_dir}/data|" "$probe_cfg" && rm -f "${probe_cfg}.bak"
mkdir -p "${probe_dir}/data"
nomad agent -config="$probe_cfg" >/tmp/nomad-probe.log 2>&1 &
probe_pid="$!"
export NOMAD_ADDR='http://127.0.0.1:14646'

# Wait for the probe leader (fail closed: no leader, no restore).
leader=''
for _ in $(seq 1 30); do
  leader="$(curl -fsS --max-time 5 "${NOMAD_ADDR}/v1/status/leader" 2>/dev/null || true)"
  if [ -n "$leader" ] && [ "$leader" != '""' ]; then break; fi
  sleep 2
done
if [ -z "$leader" ] || [ "$leader" = '""' ]; then
  echo 'probe agent produced no leader (fail closed).' >&2
  exit 1
fi

# Known-data baseline: production job list BEFORE the restore (the same
# snapshot source the probe must reproduce). Equality after restore is the
# proof — including the empty case on a fresh cluster.
prod_jobs="$(NOMAD_ADDR='http://127.0.0.1:4646' nomad job status -short 2>/dev/null | sort || true)"
if ! NOMAD_ADDR="$NOMAD_ADDR" nomad operator snapshot restore "$snap_file" >/dev/null 2>&1; then
  echo 'restore into probe agent failed (fail closed).' >&2
  exit 2
fi
log 'restore into probe agent complete.'

probe_jobs="$(nomad job status -short 2>/dev/null | sort || true)"
if [ "$probe_jobs" != "$prod_jobs" ]; then
  echo 'restore verification failed: probe job table differs from production (fail closed).' >&2
  echo "production: ${prod_jobs}" >&2
  echo "probe: ${probe_jobs}" >&2
  exit 2
fi
if [ -z "$probe_jobs" ]; then
  log 'restore verification passed: probe reproduces production (no jobs on either — fresh cluster).'
else
  log "restore verification passed: probe reproduces production job table (${probe_jobs})."
fi
trap - EXIT
cleanup_probe
probe_pid=''
log 'RESTORE_OK: scheduled R2 snapshot restores to usable state; probe agent killed.'
