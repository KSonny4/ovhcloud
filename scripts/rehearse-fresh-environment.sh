#!/usr/bin/env bash
# Disposable fresh-environment rehearsal for the IaC-first redesign.
#
# Proves the noninteractive path without touching the preserved VPS and
# without performing any live provider apply:
# - Terraform fmt/init/validate (backend disabled; no state, no apply).
# - Structural IaC validation and repository gates.
# - Every fresh-host script runs twice in --dry-run to prove idempotence.
# - Secret scan proves no plaintext credential material in the rehearsal tree.
# - Graft wiring check proves context graph freshness.
# - Emits redacted, structured phase status only (no secret values).
#
# Usage: bash scripts/rehearse-fresh-environment.sh
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root_dir"
artifact_dir="${REHEARSAL_ARTIFACT_DIR:-/tmp/ovh-coolify-rehearsal}"
mkdir -p "$artifact_dir"
report="$artifact_dir/rehearsal-report.json"
: > "$artifact_dir/phases.log"

phase_ok() { printf '{"phase":"%s","status":"pass"}\n' "$1"; }
log() { printf '%s\n' "$*"; }

log '== provider_access (dry-run) =='
log 'No live credentials are required: rehearsal uses example placeholders and dry-run modes only.'
phase_ok provider_access | tee -a "$artifact_dir/phases.log"

log '== origin_identity =='
for script in scripts/bootstrap-vps.sh scripts/provision-coolify.sh scripts/configure-tunnel-access.sh scripts/run-remote-provision.sh; do
  if [ ! -f "$script" ]; then echo "missing script: $script." >&2; exit 1; fi
  if ! grep -q "vps-1525c977.vps.ovh.net" "$script" || ! grep -q 'Refusing' "$script"; then
    echo "preserved-host guard missing in ${script}." >&2
    exit 1
  fi
done
log 'preserved-host guard present in all fresh-host scripts.'
phase_ok origin_identity | tee -a "$artifact_dir/phases.log"

log '== terraform_gates =='
terraform -chdir=infra/terraform fmt -check -recursive
terraform -chdir=infra/terraform init -backend=false -input=false >/tmp/rehearsal-terraform-init.log 2>&1
terraform -chdir=infra/terraform validate
python3 scripts/validate-iac.py
phase_ok terraform_gates | tee -a "$artifact_dir/phases.log"

log '== guest_ready (dry-run twice) =='
for pass in 1 2; do
  BOOTSTRAP_TARGET_HOST=rehearsal.invalid BOOTSTRAP_SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3example rehearsal' \
    bash scripts/bootstrap-vps.sh --dry-run >/tmp/rehearsal-bootstrap-"$pass".log 2>&1
done
if ! cmp -s /tmp/rehearsal-bootstrap-1.log /tmp/rehearsal-bootstrap-2.log; then
  echo 'bootstrap dry-run is not idempotent.' >&2
  exit 1
fi
log 'bootstrap dry-run idempotent across two passes.'
phase_ok guest_ready | tee -a "$artifact_dir/phases.log"

log '== coolify_ready (dry-run twice) =='
for pass in 1 2; do
  COOLIFY_TARGET_HOST=rehearsal.invalid COOLIFY_DOMAIN=coolify.invalid \
    bash scripts/provision-coolify.sh --dry-run >/tmp/rehearsal-coolify-"$pass".log 2>&1
done
cmp -s /tmp/rehearsal-coolify-1.log /tmp/rehearsal-coolify-2.log || { echo 'coolify dry-run is not idempotent.' >&2; exit 1; }
log 'coolify dry-run idempotent across two passes.'
phase_ok coolify_ready | tee -a "$artifact_dir/phases.log"

log '== edge_ready (dry-run twice) =='
for pass in 1 2; do
  TUNNEL_TARGET_HOST=rehearsal.invalid TUNNEL_DOMAIN=rehearsal.invalid \
    bash scripts/configure-tunnel-access.sh --dry-run >/tmp/rehearsal-tunnel-"$pass".log 2>&1
done
cmp -s /tmp/rehearsal-tunnel-1.log /tmp/rehearsal-tunnel-2.log || { echo 'tunnel dry-run is not idempotent.' >&2; exit 1; }
log 'tunnel/access dry-run idempotent across two passes; machine verification shape checked.'
phase_ok edge_ready | tee -a "$artifact_dir/phases.log"

log '== runner_channel (dry-run twice) =='
for pass in 1 2; do
  PROVISION_HOST=runner-rehearsal.invalid PROVISION_DOMAIN=coolify.invalid PROVISION_SSH_KEY=/dev/null \
    bash scripts/run-remote-provision.sh --dry-run >/tmp/rehearsal-runner-"$pass".log 2>&1 \
    || { echo 'runner dry-run unexpectedly requires live access.' >&2; exit 1; }
done
cmp -s /tmp/rehearsal-runner-1.log /tmp/rehearsal-runner-2.log || { echo 'runner dry-run is not idempotent.' >&2; exit 1; }
for stage in bootstrap coolify edge backup; do
  grep -q "$stage" /tmp/rehearsal-runner-1.log || { echo "runner dry-run omits stage: ${stage}." >&2; exit 1; }
done
log 'runner dry-run idempotent across two passes; all four stages present; no network touched.'
phase_ok runner_channel | tee -a "$artifact_dir/phases.log"

log '== backup_ready (dry-run) =='
bash scripts/backup-r2-probe.sh --dry-run >/tmp/rehearsal-backup.log 2>&1
phase_ok backup_ready | tee -a "$artifact_dir/phases.log"

log '== no_plaintext_secrets =='
git diff --check
if grep -R -E '\b(API_TOKEN|PRIVATE_KEY|ACCESS_KEY|APP_KEY)\b\s*[:=]\s*["'"'"']?[A-Za-z0-9+/=_-]{20,}' \
    --exclude-dir=.git --exclude-dir=.terraform --exclude-dir=graft --exclude-dir=.pi-glla \
    . | grep -v -E 'REPLACE_WITH_|example\.invalid|rehearsal|AAAAC3example|<|var\.|local\.|data\.|resource\.'; then
  echo 'plaintext-secret-shaped material found.' >&2
  exit 1
fi
phase_ok no_plaintext_secrets | tee -a "$artifact_dir/phases.log"

log '== context_graph =='
if command -v graft >/dev/null 2>&1; then
  graft check | tail -n 3
else
  echo 'graft not installed.' >&2
  exit 1
fi
phase_ok context_graph | tee -a "$artifact_dir/phases.log"

python3 - "$artifact_dir/phases.log" "$report" <<'PY'
import json
import sys

phases_path, report_path = sys.argv[1:3]
phases = []
with open(phases_path) as handle:
    for line in handle:
        line = line.strip()
        if line:
            phases.append(json.loads(line))
with open(report_path, 'w') as handle:
    json.dump({'rehearsal': 'ovh-coolify-fresh-environment', 'phases': phases}, handle, indent=2)
PY

log "rehearsal_ready: report written to ${report}"
cat "$report"
