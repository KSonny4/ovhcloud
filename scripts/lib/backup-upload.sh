#!/usr/bin/env bash
# Shared backup-upload helpers (probe §5 repair, #2153).
#
# Sourced by scripts/backup-app-workloads.sh and the generated
# /root/host-backup/backup-to-r2.sh. Pure bash + aws CLI; stdlib only
# otherwise. Never prints secret values (keys/paths/sizes only).
#
# Required environment: R2_ENDPOINT, R2_BUCKET. aws CLI on PATH.
# Test seam: BACKUP_SLEEP overrides the sleep command (fixture tests set it
# to a recorder); BACKUP_SIZE_GATE_BYTES overrides the 4 GiB gate so
# fixtures never allocate giant files.
#
# Fail-closed throughout: any refusal or exhaustion returns nonzero and the
# callers exit nonzero without a green manifest.

# >4 GiB pre-upload refuse-and-name gate: single-PUT caps at ~5 GiB and the
# aws CLI buffers the body in RAM (09-20 burned 5.5 min + 7.6 GB peak), so
# anything over 4 GiB is refused in ~1s with the offending key named.
BACKUP_SIZE_GATE_BYTES="${BACKUP_SIZE_GATE_BYTES:-4294967296}"
# Snapshot-save retry bound (09-21 died on a Nomad snapshot 429): attempts
# with 5/10/20/40s backoff, then fail closed.
BACKUP_SNAPSHOT_ATTEMPTS="${BACKUP_SNAPSHOT_ATTEMPTS:-5}"
BACKUP_SLEEP="${BACKUP_SLEEP:-sleep}"

# Explicit giant excludes — CONFIG ONLY, no data deletion. Each giant is
# its own line so any one of them reverts independently by deleting that
# line. Rationale per giant (probe §3): decommissioned migration data that
# must never ride the nightly; media dumps restorable from source; registry
# blobs are content-addressed and re-pushable. Env APP_BIND_EXCLUDE
# overrides the whole default (newline-separated).
_backup_default_excludes() {
  printf '%s\n' '/srv/old-vps-migration'
  printf '%s\n' '/opt/nomad-volumes/dump-prod-media'
  printf '%s\n' '/opt/nomad-volumes/registry'
}

# backup_bind_excluded PATH — 0 (excluded) when PATH is one of the giants
# or lives under one; 1 otherwise.
backup_bind_excluded() {
  local path="$1" excl
  if [ -n "${APP_BIND_EXCLUDE:-}" ]; then
    while IFS= read -r excl; do
      [ -n "$excl" ] || continue
      if [ "$path" = "$excl" ] || [[ "$path" == "$excl/"* ]]; then return 0; fi
    done <<<"$APP_BIND_EXCLUDE"
    return 1
  fi
  while IFS= read -r excl; do
    [ -n "$excl" ] || continue
    if [ "$path" = "$excl" ] || [[ "$path" == "$excl/"* ]]; then return 0; fi
  done < <(_backup_default_excludes)
  return 1
}

# Portable file size in bytes (GNU + BSD stat).
backup_file_bytes() {
  local f="$1" n
  n="$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo '')"
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

# backup_gate_check FILE R2_KEY — the refuse-and-name gate alone (no upload).
# Returns 0 when the payload may be attempted, 1 with the offending key named.
# Lets callers pair a different transport (e.g. lib/s3-multipart.sh progress
# uploads) with the same fail-closed size contract.
backup_gate_check() {
  local file="$1" key="$2" bytes
  bytes="$(backup_file_bytes "$file")" || { echo "REFUSED unreadable payload: key=${key} file=${file}." >&2; return 1; }
  if [ "$bytes" -gt "$BACKUP_SIZE_GATE_BYTES" ]; then
    echo "REFUSED oversized payload: key=${key} bytes=${bytes} exceeds gate=${BACKUP_SIZE_GATE_BYTES} file=${file}." >&2
    return 1
  fi
  return 0
}

# backup_upload LOCAL_FILE R2_KEY — gate, then multipart-routed upload
# (aws s3 cp multilparts automatically; single-PUT is never used for
# payloads), then head-object verify. Refusals name the offending key.
backup_upload() {
  local file="$1" key="$2"
  backup_gate_check "$file" "$key" || return 1
  aws --endpoint-url "$R2_ENDPOINT" s3 cp "$file" "s3://${R2_BUCKET}/${key}" >/dev/null || return 1
  aws --endpoint-url "$R2_ENDPOINT" s3api head-object --bucket "$R2_BUCKET" --key "$key" >/dev/null || return 1
  return 0
}

# backup_snapshot_save TMP_FILE — nomad snapshot save with retry-with-
# backoff for the 429 class (09-21 mode). Bounded attempts, then fail
# closed. Backoff: 5/10/20/40s.
backup_snapshot_save() {
  local tmp="$1" attempt=1 delay=5
  while [ "$attempt" -le "$BACKUP_SNAPSHOT_ATTEMPTS" ]; do
    if nomad operator snapshot save "$tmp" 2>/dev/null; then return 0; fi
    if [ "$attempt" -eq "$BACKUP_SNAPSHOT_ATTEMPTS" ]; then
      echo "FAILED snapshot save after ${attempt} attempts (fail closed)." >&2
      return 1
    fi
    "$BACKUP_SLEEP" "$delay" 2>/dev/null || sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
  return 1
}
