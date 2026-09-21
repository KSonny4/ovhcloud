#!/usr/bin/env bash
# Fixture test for the backup repair (probe §5, #2153): size gate, giant
# excludes, multipart routing, snapshot-save backoff.
#
# Pure fixture: stubbed aws/nomad/sleep, tiny temp files only (thresholds
# driven via BACKUP_SIZE_GATE_BYTES so no giant fixture is ever allocated),
# no network, no credentials, no host state. Fails closed on any regression.
#
# Usage: bash scripts/test-backup-gates.sh
set -u

lib_src="$(cd "$(dirname "$0")" && pwd)/lib/backup-upload.sh"
fail=0
pass=0
ok() { pass=$((pass + 1)); echo "ok: $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1" >&2; }

[ -f "$lib_src" ] || { echo 'FAIL: lib missing: scripts/lib/backup-upload.sh' >&2; echo 'GATE TEST: FAIL (red)'; exit 1; }

# shellcheck disable=SC1090
. "$lib_src"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
AWS_LOG="$work/aws.log"; : >"$AWS_LOG"
NOMAD_FAILS=0; NOMAD_CALLS="$work/nomad.calls"; : >"$NOMAD_CALLS"
SLEEPS="$work/sleeps"; : >"$SLEEPS"

aws() { printf '%s\n' "$*" >>"$AWS_LOG"; [ "${AWS_RC:-0}" -eq 0 ]; }
nomad() {
  printf '%s\n' "$*" >>"$NOMAD_CALLS"
  if [ "$NOMAD_FAILS" -gt 0 ]; then NOMAD_FAILS=$((NOMAD_FAILS - 1)); echo '429 rate-limited' >&2; return 1; fi
  [ "${4:-}" != '' ] && : >"$4"
  return 0
}
fake_sleep() { printf '%s\n' "$1" >>"$SLEEPS"; }
BACKUP_SLEEP=fake_sleep
export BACKUP_SLEEP
export R2_ENDPOINT='https://fixture.invalid' R2_BUCKET='fixture-bucket'

# --- 1. size gate: refuse-and-name over 4 GiB default ---
printf '0123456789ABCDEF' >"$work/sixteen.bin"   # 16 bytes
if BACKUP_SIZE_GATE_BYTES=10 backup_upload "$work/sixteen.bin" 'app-binds/BIG-123.tar.gz' 2>"$work/err"; then
  bad 'gate accepted 16 bytes over a 10-byte gate'
else
  if grep -q 'app-binds/BIG-123.tar.gz' "$work/err"; then ok 'gate refuses and names the offending key'; else bad 'gate refusal did not name the key'; fi
  if grep -q 'app-binds/BIG-123.tar.gz' "$AWS_LOG"; then bad 'refused payload reached aws'; else ok 'refused payload never reached aws'; fi
fi

# --- 2. size gate: under-threshold payload routes via multipart-capable cp ---
printf '123456789' >"$work/nine.bin"               # 9 bytes
: >"$AWS_LOG"
if BACKUP_SIZE_GATE_BYTES=10 backup_upload "$work/nine.bin" 'app-volumes/small-1.tar.gz' 2>/dev/null; then
  if grep -q '^--endpoint-url .* s3 cp ' "$AWS_LOG"; then ok 'upload routes via aws s3 cp (auto-multipart)'; else bad 'upload did not use aws s3 cp'; fi
  if grep -q 's3api put-object' "$AWS_LOG"; then bad 'upload used single-PUT s3api put-object'; else ok 'upload never uses single-PUT'; fi
else
  bad 'gate refused a 16-byte payload under a 10-byte... (setup error)'
fi

# --- 3. gate boundary: exactly at gate passes, one byte over refuses ---
printf '1234567890' >"$work/ten.bin"             # 10 bytes
if BACKUP_SIZE_GATE_BYTES=10 backup_upload "$work/ten.bin" 'k/at.bin' >/dev/null 2>&1; then ok 'at-gate size passes'; else bad 'at-gate size refused'; fi
printf '1234567890X' >"$work/eleven.bin"         # 11 bytes
if BACKUP_SIZE_GATE_BYTES=10 backup_upload "$work/eleven.bin" 'k/over.bin' >/dev/null 2>&1; then bad 'over-gate size passed'; else ok 'over-gate size refuses'; fi

# --- 4. giant excludes: the three probe giants match, small fry does not ---
unset APP_BIND_EXCLUDE
for g in '/srv/old-vps-migration' '/opt/nomad-volumes/dump-prod-media' '/opt/nomad-volumes/registry'; do
  if backup_bind_excluded "$g"; then ok "giant excluded: $g"; else bad "giant NOT excluded: $g"; fi
done
if backup_bind_excluded '/opt/nomad-volumes/cognee-store'; then bad 'small fry wrongly excluded'; else ok 'small fry not excluded'; fi
if backup_bind_excluded '/opt/nomad-volumes/registry/sub/blob'; then ok 'giant subtree excluded'; else bad 'giant subtree NOT excluded'; fi

# --- 5. excludes are config: one-line revert each, env override respected ---
if grep -c -E '^/srv/old-vps-migration$' "$lib_src" >/dev/null 2>&1; then :; fi
lines="$(grep -c -E "old-vps-migration|/opt/nomad-volumes/dump-prod-media|/opt/nomad-volumes/registry'" "$lib_src" || true)"
if [ "$lines" -ge 3 ]; then ok 'each giant on its own config line (one-line revert each)'; else bad 'giants not on individual config lines'; fi
if APP_BIND_EXCLUDE='/data/keep' backup_bind_excluded '/srv/old-vps-migration'; then bad 'env override ignored'; else ok 'APP_BIND_EXCLUDE override respected'; fi

# --- 6. snapshot retry-with-backoff: 2x429 then green, backoff slept ---
NOMAD_FAILS=2; : >"$NOMAD_CALLS"; : >"$SLEEPS"
if backup_snapshot_save "$work/snap.snap"; then
  calls="$(wc -l <"$NOMAD_CALLS" | tr -d ' ')"
  if [ "$calls" -eq 3 ]; then ok 'snapshot retried to green on 3rd attempt'; else bad "snapshot attempts = $calls, want 3"; fi
  sleeps="$(tr '\n' ' ' <"$SLEEPS")"
  if [ "$sleeps" = '5 10 ' ]; then ok 'backoff slept 5 then 10'; else bad "backoff sleeps = [$sleeps], want [5 10 ]"; fi
else
  bad 'snapshot retry gave up despite eventual green'
fi

# --- 7. snapshot exhaustion fails closed ---
NOMAD_FAILS=99; : >"$NOMAD_CALLS"; : >"$SLEEPS"
if backup_snapshot_save "$work/snap2.snap" 2>/dev/null; then bad 'exhausted snapshot save returned 0'; else ok 'exhausted snapshot save fails closed'; fi
if [ "$(wc -l <"$NOMAD_CALLS" | tr -d ' ')" -eq 5 ]; then ok 'snapshot attempts bounded at 5'; else bad 'snapshot attempts not bounded at 5'; fi

trap - EXIT; rm -rf "$work"
if [ "$fail" -eq 0 ]; then echo "GATE TEST: PASS ($pass checks)"; else echo "GATE TEST: FAIL ($fail failures, $pass passed)" >&2; exit 1; fi
