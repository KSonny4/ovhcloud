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
# The guard must be the shared service-identity library, not bypassable
# two-literal comparisons: every fresh-host entry point sources it, and none
# may retain the old literal IP/hostname OR-comparison.
if [ ! -f scripts/lib/preserved-guard.sh ]; then echo 'guard library missing.' >&2; exit 1; fi
for script in scripts/bootstrap-vps.sh scripts/provision-coolify.sh scripts/configure-tunnel-access.sh scripts/run-remote-provision.sh; do
  if ! grep -q 'lib/preserved-guard.sh' "$script"; then
    echo "shared guard not sourced in ${script}." >&2
    exit 1
  fi
  if grep -q "target.*=.*'vps-1525c977" "$script" || grep -q 'host.*=.*57\.129\.155\.203' "$script"; then
    echo "bypassable literal guard still present in ${script}." >&2
    exit 1
  fi
done
log 'shared service-identity guard sourced by all fresh-host entry points; no literal guards remain.'
phase_ok origin_identity | tee -a "$artifact_dir/phases.log"

log '== terraform_gates =='
terraform -chdir=infra/terraform fmt -check -recursive
terraform -chdir=infra/terraform init -backend=false -input=false >/tmp/rehearsal-terraform-init.log 2>&1
terraform -chdir=infra/terraform validate
python3 scripts/validate-iac.py
log '== admin policy regression gate (omission must fail) =='
# Plan requires an initialized backend, which the credential-free rehearsal
# deliberately lacks — so the gate runs in a throwaway copy with the partial
# s3 backend stripped (same shape as the committed configuration otherwise).
gate_dir="$(mktemp -d /tmp/admin-gate.XXXXXX)"
cp infra/terraform/main.tf infra/terraform/variables.tf infra/terraform/versions.tf infra/terraform/outputs.tf "$gate_dir/"
python3 - "$gate_dir/versions.tf" <<'PY'
import re, sys
p = sys.argv[1]
t = open(p).read()
t = re.sub(r'\n  backend "s3" \{\}', '', t)
open(p, 'w').write(t)
PY
terraform -chdir="$gate_dir" init -backend=false -input=false >/tmp/rehearsal-gate-init.log 2>&1
# NOTE: the export builtin (unlike a command env-prefix) accepts a quoted
# NAME=value argument, which the JSON list value requires.
export TF_VAR_cloudflare_api_token=rehearsal
export TF_VAR_cloudflare_account_id=5eb3ea3a84b37564cfd8739f32ffb559
export TF_VAR_domain=pkubelka.cz
export TF_VAR_ovh_ipv4=192.0.2.1
export TF_VAR_cloudflare_tunnel_secret=cmVoZWFyc2Fs
export 'TF_VAR_admin_emails=["intruder@example.invalid"]'
# NOTE: plan exits nonzero on the expected validation failure; capture output
# first because pipefail would otherwise mask grep's match.
plan_out="$(terraform -chdir="$gate_dir" plan -input=false 2>&1 || true)"
if printf '%s' "$plan_out" | grep -q 'must retain ksonny4@gmail.com'; then
  log 'omitting ksonny4@gmail.com fails closed with the retention error.'
else
  echo 'admin_emails regression gate broken: omission did not fail.' >&2
  exit 1
fi
unset TF_VAR_cloudflare_api_token TF_VAR_cloudflare_account_id TF_VAR_domain TF_VAR_ovh_ipv4 TF_VAR_cloudflare_tunnel_secret TF_VAR_admin_emails
rm -rf "$gate_dir"
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
if ! grep -q 'exactly HTTP 200' /tmp/rehearsal-tunnel-1.log && ! grep -q 'HTTP 200' scripts/configure-tunnel-access.sh; then
  echo 'tunnel verification is not 200-only.' >&2; exit 1
fi
if grep -q '302)' scripts/configure-tunnel-access.sh || grep -q '|| true' scripts/configure-tunnel-access.sh; then
  echo 'tunnel script still tolerates redirects or suppresses health failure.' >&2; exit 1
fi
DASHBOARD_LOGIN_URL='https://coolify.rehearsal.invalid/login' \
  bash scripts/ensure-service-token.sh --dry-run >/tmp/rehearsal-lifecycle.log 2>&1
log 'tunnel/access dry-run idempotent across two passes; 200-only verification enforced; lifecycle dry-run clean.'
phase_ok edge_ready | tee -a "$artifact_dir/phases.log"

log '== runner_channel (dry-run twice) =='
for pass in 1 2; do
  PROVISION_HOST=runner-rehearsal.invalid PROVISION_ZONE=rehearsal.invalid PROVISION_SSH_KEY=/dev/null \
    bash scripts/run-remote-provision.sh --dry-run >/tmp/rehearsal-runner-"$pass".log 2>&1 \
    || { echo 'runner dry-run unexpectedly requires live access.' >&2; exit 1; }
done
cmp -s /tmp/rehearsal-runner-1.log /tmp/rehearsal-runner-2.log || { echo 'runner dry-run is not idempotent.' >&2; exit 1; }
for stage in bootstrap coolify edge backup; do
  grep -q "$stage" /tmp/rehearsal-runner-1.log || { echo "runner dry-run omits stage: ${stage}." >&2; exit 1; }
done
# End-to-end domain-contract test: zone rehearsal.invalid must derive the
# dashboard hostname coolify.rehearsal.invalid everywhere (FQDN, ingress,
# verification) — never the bare zone, never a doubled prefix.
grep -q 'dashboard hostname: coolify.rehearsal.invalid' /tmp/rehearsal-runner-1.log || { echo 'runner domain contract broken.' >&2; exit 1; }
if grep -q 'coolify.coolify\.' /tmp/rehearsal-runner-1.log; then echo 'doubled dashboard prefix.' >&2; exit 1; fi
# Regression gate for the fresh-host partial-backup failure: the runner must
# stage the workload companion alongside the schedule script, and the
# schedule script must install both timer commands.
grep -q 'backup-app-workloads.sh' scripts/run-remote-provision.sh || { echo 'runner does not stage backup-app-workloads.sh.' >&2; exit 1; }
grep -q "fetch-r2-env.sh -- \${app_installed}" scripts/schedule-coolify-backup.sh || { echo 'schedule script omits the workload ExecStart via fetch wrapper.' >&2; exit 1; }
# Secret-delivery gates: no script may (re)create a static R2 credential file;
# delivery is memory-only via fetch-r2-env.sh, and the unit must exec through it.
grep -q 'fetch-r2-env.sh' scripts/schedule-coolify-backup.sh || { echo 'schedule script omits the fetch wrapper.' >&2; exit 1; }
if grep -rnE '(tee|>)[^|]*r2\.env' scripts/*.sh | grep -v test-clean-target-install >/dev/null; then echo 'a script still writes r2.env.' >&2; exit 1; fi
if grep -q 'EnvironmentFile=.*r2' scripts/schedule-coolify-backup.sh; then echo 'unit still consumes a credential EnvironmentFile.' >&2; exit 1; fi
grep -q 'wire-fresh-edge.sh' scripts/run-remote-provision.sh || { echo 'runner omits fresh-edge wiring.' >&2; exit 1; }
# OVH authorization boundary: no script may read the local OVH credential file; OVH_* must come
# from the OpenBao OVH_API escrow.
if grep -rn '\.ovh\.conf' scripts/*.sh scripts/lib/*.sh 2>/dev/null | grep -v 'rehearse-fresh-environment.sh' | grep -q .; then echo 'a script still depends on the local OVH credential file.' >&2; exit 1; fi
grep -q 'OVH_API' scripts/tf-env-from-openbao.sh || { echo 'loader omits the OVH_API escrow.' >&2; exit 1; }
grep -q 'export OVH_APPLICATION_KEY' scripts/tf-env-from-openbao.sh scripts/run-remote-provision.sh || { echo 'OVH_* env emission missing.' >&2; exit 1; }
# First-access determinism gates: key-only minting, destructive reinstall
# with freshness confirmation, and fail-closed SSH probe with guidance.
for gate in --generate-key-only --reinstall-with-key --i-confirm-host-is-fresh; do
  grep -q -- "$gate" scripts/run-remote-provision.sh || { echo "runner omits first-access mode: ${gate}." >&2; exit 1; }
done
grep -q 'Deterministic options' scripts/run-remote-provision.sh || { echo 'runner omits fail-closed first-access guidance.' >&2; exit 1; }
# Memory-only enforcement gates: no backup/rollback path may accept or read
# a credential file, ever.
if grep -rn -- '--env-file' scripts/backup-app-workloads.sh scripts/rollback-coolify-backup.sh scripts/schedule-coolify-backup.sh scripts/fetch-r2-env.sh >/dev/null; then echo 'a backup/rollback script still accepts --env-file.' >&2; exit 1; fi
if grep -rn "source \"\\\$env_file\"" scripts/backup-app-workloads.sh scripts/rollback-coolify-backup.sh >/dev/null; then echo 'a backup/rollback script still sources a credential file.' >&2; exit 1; fi
# Complete administration path: the runner must wire BOTH dashboard and SSH
# routes (DNS + ingress + Access), and record the Terraform handoff.
for gate in 'SSH_HOSTNAME=' '--handoff-file' 'emit-fresh-imports.sh'; do
  grep -q -- "$gate" scripts/run-remote-provision.sh || { echo "runner omits complete edge path: ${gate}." >&2; exit 1; }
done
for gate in 'SSH_HOSTNAME' 'ssh://localhost:22' 'access_app_id' 'emit-fresh-imports'; do
  grep -q -- "$gate" scripts/wire-fresh-edge.sh || { echo "wire script omits SSH/Access/handoff: ${gate}." >&2; exit 1; }
done
log '== edge_routes (dry-run, zero network) =='
CLOUDFLARE_ACCOUNT_ID=rehearsal CLOUDFLARE_ZONE_ID=rehearsal TUNNEL_ID=rehearsal-tunnel \
  EDGE_HOSTNAME=coolify.rehearsal.invalid SSH_HOSTNAME=ssh.rehearsal.invalid \
  bash scripts/wire-fresh-edge.sh --dry-run --handoff-file /tmp/rehearsal-handoff.json > /tmp/rehearsal-edge.log 2>&1 \
  || { echo 'wire dry-run failed.' >&2; exit 1; }
for host in coolify.rehearsal.invalid ssh.rehearsal.invalid; do
  grep -q "$host" /tmp/rehearsal-edge.log || { echo "wire dry-run omits route: ${host}." >&2; exit 1; }
done
grep -q 'ssh://localhost:22' /tmp/rehearsal-edge.log || { echo 'wire dry-run omits the ssh ingress route.' >&2; exit 1; }
rm -f /tmp/rehearsal-handoff.json
printf '{"tunnel_id":"t","routes":[{"hostname":"h","service":"s","dns_record_id":"d","access_app_id":"a","policy_ids":["p"]}]}' > /tmp/rehearsal-handoff.json
CLOUDFLARE_ACCOUNT_ID=rehearsal CLOUDFLARE_ZONE_ID=rehearsal \
  bash scripts/emit-fresh-imports.sh --handoff /tmp/rehearsal-handoff.json > /tmp/rehearsal-imports.log 2>&1 \
  || { echo 'emit imports failed on synthetic handoff.' >&2; exit 1; }
grep -q 'accounts/rehearsal/a' /tmp/rehearsal-imports.log || { echo 'emit imports omits the access app block.' >&2; exit 1; }
rm -f /tmp/rehearsal-handoff.json
log 'edge routes proven in dry-run: dashboard + ssh ingress/DNS/Access planned, handoff import blocks emit.'
log 'runner dry-run idempotent across two passes; all four stages present; backup companion staged + scheduled; fileless R2 delivery enforced; fresh edge wired; no network touched.'
phase_ok runner_channel | tee -a "$artifact_dir/phases.log"

log '== backup_ready (dry-run) =='
bash scripts/backup-r2-probe.sh --dry-run >/tmp/rehearsal-backup.log 2>&1
bash scripts/rollback-coolify-backup.sh --dry-run >>/tmp/rehearsal-backup.log 2>&1
bash scripts/tf-env-from-openbao.sh --dry-run >>/tmp/rehearsal-backup.log 2>&1
phase_ok backup_ready | tee -a "$artifact_dir/phases.log"

log '== ephemeral_cleanup (no credential files; memory-only transport) =='
# Credential-bearing files must not exist: no tfvars (env-only Terraform),
# no stage.env anywhere (base64-blob transport). Failure here fails closed.
if [ -e infra/terraform/terraform.tfvars ]; then echo 'live terraform.tfvars present; shred it.' >&2; exit 1; fi
if find . /tmp -maxdepth 2 -name 'stage.env' -not -path './.git/*' 2>/dev/null | grep -q .; then
  echo 'stage.env artifact present; remove it.' >&2; exit 1
fi
if find . -maxdepth 3 -name 'terraform.tfvars' -not -path './.git/*' 2>/dev/null | grep -q .; then
  echo 'terraform.tfvars artifact present in repo; remove it.' >&2; exit 1
fi
# Structural: the runner must carry credentials only in the base64 blob — no
# credential-file shipment or remote sourcing remains outside comments.
if grep -vE '^\s*#' scripts/run-remote-provision.sh | grep -qE 'scp[^#]*stage\.env|source [^ ]*stage\.env'; then
  echo 'runner still ships/sources a credential file.' >&2; exit 1
fi
if ! grep -q 'base64 -d' scripts/run-remote-provision.sh; then
  echo 'runner blob transport missing.' >&2; exit 1
fi
log 'no credential files exist; memory-only transport structurally verified.'
phase_ok ephemeral_cleanup | tee -a "$artifact_dir/phases.log"

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
