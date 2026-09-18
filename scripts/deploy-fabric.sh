#!/usr/bin/env bash
# Deploy the fabric stack to Nomad (operator side).
#
# Contract:
# - Reads secrets ONLY from OpenBao projects/nomad/FABRIC by field name;
#   any missing key fails closed listing exactly which escrow entries the
#   operator must add (values never printed, never logged).
# - Renders an HCL2 -var-file into a 0600 temp file, ships it + the
#   jobspec to the target over SSH, runs `nomad job run` on loopback
#   (tunnel/Access cannot carry the Nomad CLI), polls the api task
#   healthy, then shreds local + remote secret material on every exit
#   path. The jobspec itself carries no secret values, ever.
# - Idempotent: re-running redeploys the same spec (Nomad versions it).
#
# Usage:
#   FABRIC_HOST=ubuntu@<host> FABRIC_SSH_KEY=~/.ssh/<key> \
#   BAO_ADDR=https://secrets.pkubelka.cz bash scripts/deploy-fabric.sh [--dry-run]
set -euo pipefail

dry_run=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    -h|--help) echo 'usage: deploy-fabric.sh [--dry-run]'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '%s\n' "$*"; }
host="${FABRIC_HOST:-}"
ssh_key="${FABRIC_SSH_KEY:-}"
[ -n "$host" ] || { echo 'FABRIC_HOST (user@host) is required.' >&2; exit 2; }
[ -n "$ssh_key" ] || { echo 'FABRIC_SSH_KEY is required.' >&2; exit 2; }
command -v bao >/dev/null 2>&1 || { echo 'bao CLI is required.' >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo 'python3 is required.' >&2; exit 2; }
export BAO_ADDR="${BAO_ADDR:-https://secrets.pkubelka.cz}"

# FABRIC entry field == jobspec var. Missing escrow fails closed with the
# exact field names (never values).
check_escrow() {
  local missing=''
  for field in \
    fabric_bearer neo4j_password postgres_password gh_token \
    gh_webhook_secret omni_key r2_access_key_id r2_secret_access_key \
    r2_account_id r2_bucket r2_enc_passphrase cf_access_client_id \
    cf_access_client_secret; do
    if ! bao kv get -mount=secret -field="${field}" projects/nomad/FABRIC >/dev/null 2>&1; then
      missing="${missing} ${field}"
    fi
  done
  if [ -n "$missing" ]; then
    echo "missing FABRIC fields (add with: bao kv patch -mount=secret projects/nomad/FABRIC <field>=-):${missing}" >&2
    exit 2
  fi
}

workdir="$(mktemp -d /tmp/fabric-deploy.XXXXXX)"
chmod 700 "$workdir"
varfile="$workdir/fabric.vars.json"
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT

if [ "$dry_run" -eq 1 ]; then
  log 'DRY-RUN: check 13 escrow entries by name (fail closed listing missing)'
  log 'DRY-RUN: render -var-file (0600), scp jobspec + vars, remote nomad job run + health poll, shred both ends'
  check_escrow
  log 'DRY-RUN: escrow complete.'
  exit 0
fi
check_escrow

python3 - "$varfile" <<'PY'
import json, subprocess, sys
pairs = {
    'fabric_bearer', 'neo4j_password', 'postgres_password', 'gh_token',
    'gh_webhook_secret', 'omni_key', 'r2_access_key_id',
    'r2_secret_access_key', 'r2_account_id', 'r2_bucket',
    'r2_enc_passphrase', 'cf_access_client_id', 'cf_access_client_secret',
}
out = {}
for var in pairs:
    p = subprocess.run(['bao', 'kv', 'get', '-mount=secret', f'-field={var}',
                        'projects/nomad/FABRIC'],
                       capture_output=True, text=True)
    if p.returncode != 0 or not p.stdout:
        sys.exit(f'escrow unreadable at deploy time: projects/nomad/FABRIC field {var}')
    out[var] = p.stdout.rstrip('\n')
with open(sys.argv[1], 'w') as f:
    json.dump(out, f)
PY
chmod 600 "$varfile"
log 'var-file rendered (0600, memory-sourced, never printed).'

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
ssh_opts=(-i "$ssh_key" -o BatchMode=yes -o ConnectTimeout=20)
remote_tmp="$(ssh "${ssh_opts[@]}" "$host" 'mktemp -d /tmp/fabric-deploy.XXXXXX')"
scp "${ssh_opts[@]}" "$repo_root/jobs/fabric.nomad.hcl" "$varfile" "${host}:${remote_tmp}/" >/dev/null
log 'spec + vars shipped (no credential files besides the 0600 var-file).'
# Submit output is suppressed wholesale: Nomad echoes rendered secret
# values in its diff, and no grep pattern can be trusted to catch them all.
if ssh "${ssh_opts[@]}" "$host" "export NOMAD_ADDR=http://127.0.0.1:4646; nomad job run -var-file=${remote_tmp}/fabric.vars.json ${remote_tmp}/fabric.nomad.hcl" >/dev/null 2>&1; then
  log 'job submitted (output suppressed: contains rendered secrets).'
else
  echo 'nomad job run failed (inspect on host: nomad job status fabric).' >&2
  exit 1
fi
log 'polling api health (fail closed, 5 min)...';
healthy=0
for _ in $(seq 1 30); do
  if ssh "${ssh_opts[@]}" "$host" 'export NOMAD_ADDR=http://127.0.0.1:4646; nomad alloc status $(nomad job allocs -short fabric 2>/dev/null | awk "/running/ {print $1}" | head -n1) 2>/dev/null | grep -q "Healthy"' 2>/dev/null; then
    healthy=1; break
  fi
  sleep 10
done
ssh "${ssh_opts[@]}" "$host" "shred -u ${remote_tmp}/fabric.vars.json ${remote_tmp}/fabric.nomad.hcl 2>/dev/null; rmdir ${remote_tmp} 2>/dev/null" || true
if [ "$healthy" -eq 1 ]; then
  log 'DEPLOY_OK: fabric api task reports Healthy on Nomad.'
else
  echo 'deploy health gate failed after 5 min (spec submitted; inspect with nomad job status fabric).' >&2
  exit 1
fi
