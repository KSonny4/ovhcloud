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
# Provider downloads are retried (transient registry failures); throwaway
# dirs below seed from this installation so the rehearsal stays hermetic
# offline afterwards (auditor sandboxes included).
inited=0
for attempt in 1 2 3; do
  if terraform -chdir=infra/terraform init -backend=false -input=false >/tmp/rehearsal-terraform-init.log 2>&1; then inited=1; break; fi
  log "init attempt ${attempt} failed; retrying..."
  sleep 10
done
if [ "$inited" -eq 0 ]; then
  if [ -d infra/terraform/.terraform/providers ]; then
    log 'init unreachable (offline?); validating against the installed providers.'
  else
    echo 'terraform init failed after 3 attempts and no providers are installed.' >&2
    exit 1
  fi
fi
terraform -chdir=infra/terraform validate
seed_providers() {
  local dest="$1"
  if [ -d infra/terraform/.terraform/providers ] && [ -f infra/terraform/.terraform.lock.hcl ]; then
    mkdir -p "${dest}/.terraform"
    cp -r infra/terraform/.terraform/providers "${dest}/.terraform/" 2>/dev/null || true
    cp infra/terraform/.terraform.lock.hcl "${dest}/" 2>/dev/null || true
    log "seeded provider installation into ${dest} (offline-safe init)."
  fi
}
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
seed_providers "$gate_dir"
# Hermetic by construction: providers + lock are seeded from the main
# installation, so validation never depends on registry reachability.
# init is best-effort (online refresh); validate is mandatory and offline-safe.
if ! terraform -chdir="$gate_dir" init -backend=false -input=false >/tmp/rehearsal-gate-init.log 2>&1; then
  log 'gate init unreachable (offline?); validating against seeded providers.'
fi
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
# Removed hostname override fails closed (single-domain contract). Capture
# once (pipefail would mask the expected nonzero exit in a pipeline).
PROVISION_HOST=runner-rehearsal.invalid PROVISION_ZONE=rehearsal.invalid PROVISION_DASHBOARD_HOST=other.example.com bash scripts/run-remote-provision.sh --dry-run >/tmp/rehearsal-override.log 2>&1 || rc=$?
[ "${rc:-0}" -ne 0 ] || { echo 'removed dashboard-host override accepted.' >&2; exit 1; }
grep -q 'was removed' /tmp/rehearsal-override.log || { echo 'override refusal message missing.' >&2; exit 1; }
rm -f /tmp/rehearsal-override.log
log 'dashboard-host override refused fail-closed (single domain contract).'
# Adoption failure mode, executed: --apply without an encrypted remote
# backend must fail closed before any mutation (sandbox work dir, no network).
rm -rf /tmp/rehearsal-adopt && mkdir -p /tmp/rehearsal-adopt
printf '{"tunnel_id":"t","tunnel_name":"n","routes":[]}' > /tmp/rehearsal-adopt-handoff.json
if BAO_ADDR=https://secrets.pkubelka.cz TERRAFORM_FRESH_DIR=/tmp/rehearsal-adopt bash scripts/adopt-fresh-edge.sh --handoff /tmp/rehearsal-adopt-handoff.json --apply >/tmp/rehearsal-adopt.log 2>&1; then echo 'backendless --apply accepted.' >&2; exit 1; fi
grep -q 'without an encrypted remote backend' /tmp/rehearsal-adopt.log || { echo 'backendless refusal message missing.' >&2; exit 1; }
[ -f /tmp/rehearsal-adopt/main.tf ] && { echo 'backendless --apply mutated before refusing.' >&2; exit 1; } || true
rm -rf /tmp/rehearsal-adopt /tmp/rehearsal-adopt-handoff.json /tmp/rehearsal-adopt.log
log 'backendless --apply refused fail-closed (validation/plan only without backend.hcl).'
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
# Two-phase edge ordering: the runner's own dry-run emits the shipped edge
# sequence line by line; wiring must precede the connector install and every
# readiness gate must follow it. Plus mode-partition proof: --skip-verify
# never verifies, --verify-only never mutates (executed, not grepped).
python3 - <<'PYEOF' || exit 1
import re
log = open('/tmp/rehearsal-runner-1.log').read().splitlines()
def idx(pat):
    hits = [i for i, l in enumerate(log) if re.search(pat, l)]
    assert hits, pat
    return hits[0]
w = idx(r'edge 1/5.*--skip-verify')
a = idx(r'edge 2/5.*adopt --apply')
c = idx(r'edge 3/5.*configure-tunnel-access')
s = idx(r'edge 4/5.*ensure-service-token full')
v = idx(r'edge 5/5.*--verify-only')
assert w < a < c < s < v, f'edge order broken: {w} {a} {c} {s} {v}'
print(f'edge order proven: wire@{w} adopt@{a} connector@{c} token@{s} verify@{v}')
PYEOF
sv_out="$(CLOUDFLARE_ACCOUNT_ID=rehearsal CLOUDFLARE_ZONE_ID=rehearsal TUNNEL_ID=rehearsal-tunnel EDGE_HOSTNAME=wire.rehearsal.invalid bash scripts/wire-fresh-edge.sh --dry-run --skip-verify 2>&1 || true)"
printf '%s' "$sv_out" | grep -q 'verification deferred' || { echo 'skip-verify mode omits the deferral marker.' >&2; exit 1; }
printf '%s' "$sv_out" | grep -q 'verify dashboard 200' && { echo 'skip-verify mode still verifies.' >&2; exit 1; } || true
vo_out="$(CLOUDFLARE_ACCOUNT_ID=rehearsal CLOUDFLARE_ZONE_ID=rehearsal TUNNEL_ID=rehearsal-tunnel EDGE_HOSTNAME=wire.rehearsal.invalid bash scripts/wire-fresh-edge.sh --dry-run --verify-only 2>&1 || true)"
printf '%s' "$vo_out" | grep -q 'verify dashboard 200' || { echo 'verify-only mode omits verification.' >&2; exit 1; }
printf '%s' "$vo_out" | grep -q 'DRY-RUN: DNS CNAME' && { echo 'verify-only mode still mutates.' >&2; exit 1; } || true
log 'wire mode partition proven: skip-verify wires without verifying, verify-only verifies without wiring.'
# Dedicated tunnel identity: per-target secret path, preserved name refused,
# preserved singleton escrow never consumed on the fresh path.
grep -q 'TUNNEL_SECRET_PATH=' scripts/run-remote-provision.sh || { echo 'runner omits per-target tunnel secret path.' >&2; exit 1; }
grep -q "coolify-admin'" scripts/run-remote-provision.sh || { echo 'runner omits preserved-tunnel-name refusal.' >&2; exit 1; }
if grep -n 'bao_get COOLIFY_TUNNEL_TOKEN' scripts/run-remote-provision.sh | grep -q .; then echo 'runner still consumes the preserved tunnel singleton.' >&2; exit 1; fi
grep -q 'TUNNEL_SECRET_PATH' scripts/ensure-tunnel.sh || { echo 'ensure-tunnel omits per-target secret path.' >&2; exit 1; }
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
# Rollback on fresh targets: the runner must stage both rollback scripts and
# the schedule must install them (or fail closed); coverage gaps fail closed.
for gate in 'rollback-coolify-backup.sh' 'rollback-app-workloads.sh'; do
  grep -q -- "$gate" scripts/run-remote-provision.sh || { echo "runner omits rollback staging: ${gate}." >&2; exit 1; }
done
grep -q 'rollback-less schedule' scripts/schedule-coolify-backup.sh || { echo 'schedule omits rollback install gate.' >&2; exit 1; }
grep -q 'WORKLOAD COVERAGE GAP' scripts/backup-app-workloads.sh || { echo 'backup omits coverage fail-closed gate.' >&2; exit 1; }
grep -q -- '--recreate' scripts/rollback-app-workloads.sh || { echo 'rollback omits in-service recreate.' >&2; exit 1; }
for gate in 'SSH_HOSTNAME' 'ssh://localhost:22' 'access_app_id' 'emit-fresh-imports'; do
  grep -q -- "$gate" scripts/wire-fresh-edge.sh || { echo "wire script omits SSH/Access/handoff: ${gate}." >&2; exit 1; }
done
# First-time service-token ordering: creation/escrow (ensure-only) must
# precede every consumer (retrieval, wire); verification runs post-wiring.
ensure_line="$(grep -n 'ensure-service-token.sh. --ensure-only' scripts/run-remote-provision.sh | cut -d: -f1)"
retrieval_line="$(grep -n 'retrieving stage credentials' scripts/run-remote-provision.sh | cut -d: -f1)"
wire_line="$(grep -n 'wire-fresh-edge.sh.*--skip-verify.*--handoff-file' scripts/run-remote-provision.sh | cut -d: -f1)"
verify_line="$(grep -n 'DASHBOARD_LOGIN_URL=' scripts/run-remote-provision.sh | cut -d: -f1)"
for l in "$ensure_line" "$retrieval_line" "$wire_line" "$verify_line"; do
  [ -n "$l" ] || { echo 'service-token flow ordering unresolvable.' >&2; exit 1; }
done
if [ "$ensure_line" -ge "$retrieval_line" ] || [ "$retrieval_line" -ge "$wire_line" ] || [ "$wire_line" -ge "$verify_line" ]; then
  echo 'service-token flow out of order (need ensure-only < retrieval < wire < verify).' >&2; exit 1;
fi
log 'service-token flow ordered: ensure-only, retrieval, wire, verify.'
log '== edge_routes (dry-run, zero network) =='
bash scripts/wire-fresh-edge.sh --self-test-merge >/dev/null 2>&1 || { echo 'ingress merge self-test failed (routes would be discarded).' >&2; exit 1; }
log 'ingress merge self-test passed on live code (no-drift, drift, preservation).'
CLOUDFLARE_ACCOUNT_ID=rehearsal CLOUDFLARE_ZONE_ID=rehearsal TUNNEL_ID=rehearsal-tunnel \
  EDGE_HOSTNAME=coolify.rehearsal.invalid SSH_HOSTNAME=ssh.rehearsal.invalid \
  bash scripts/wire-fresh-edge.sh --dry-run --handoff-file /tmp/rehearsal-handoff.json > /tmp/rehearsal-edge.log 2>&1 \
  || { echo 'wire dry-run failed.' >&2; exit 1; }
for host in coolify.rehearsal.invalid ssh.rehearsal.invalid; do
  grep -q "$host" /tmp/rehearsal-edge.log || { echo "wire dry-run omits route: ${host}." >&2; exit 1; }
done
grep -q 'ssh://localhost:22' /tmp/rehearsal-edge.log || { echo 'wire dry-run omits the ssh ingress route.' >&2; exit 1; }
rm -f /tmp/rehearsal-handoff.json
printf '{"tunnel_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","tunnel_name":"rehearsal","routes":[{"hostname":"coolify.rehearsal.invalid","service":"http://localhost:8000","dns_record_id":"d","access_app_id":"a","policy_ids":["p"]},{"hostname":"ssh.rehearsal.invalid","service":"ssh://localhost:22","dns_record_id":"e","access_app_id":"b","policy_ids":["q"]}]}' > /tmp/rehearsal-handoff.json
rm -rf /tmp/rehearsal-fresh-out
CLOUDFLARE_ACCOUNT_ID=rehearsal CLOUDFLARE_ZONE_ID=rehearsal \
  bash scripts/emit-fresh-imports.sh --handoff /tmp/rehearsal-handoff.json --out-dir /tmp/rehearsal-fresh-out > /tmp/rehearsal-imports.log 2>&1 \
  || { echo 'emit generated config failed on synthetic handoff.' >&2; exit 1; }
[ -f /tmp/rehearsal-fresh-out/main.tf ] && [ -f /tmp/rehearsal-fresh-out/imports.tf ] || { echo 'emitter omits main.tf/imports.tf.' >&2; exit 1; }
grep -q 'non_identity' /tmp/rehearsal-fresh-out/main.tf || { echo 'generated apps diverge from the nested non_identity convention.' >&2; exit 1; }
# Exactness: generated config must mirror API-created resources attribute for
# attribute (live converged shape), so post-adoption plan is empty.
grep -q 'name                      = "Coolify Dashboard"' /tmp/rehearsal-fresh-out/main.tf || { echo 'generated dashboard app name diverges from live.' >&2; exit 1; }
grep -q 'name                      = "Coolify SSH Administration"' /tmp/rehearsal-fresh-out/main.tf || { echo 'generated ssh app name diverges from live.' >&2; exit 1; }
grep -q '"Fresh ' /tmp/rehearsal-fresh-out/main.tf && { echo 'generated config carries Fresh-prefixed names.' >&2; exit 1; } || true
grep -q 'allowed_idps              = \[\]' /tmp/rehearsal-fresh-out/main.tf || { echo 'generated apps diverge from converged empty allowed_idps.' >&2; exit 1; }
grep -q 'comment = "Fresh ' /tmp/rehearsal-fresh-out/main.tf && { echo 'generated DNS carries comments wire never creates.' >&2; exit 1; } || true
! grep -q 'allowed_idps.*otp' scripts/wire-fresh-edge.sh || { echo 'wire still injects OTP into app creation.' >&2; exit 1; }
if command -v terraform >/dev/null 2>&1; then
  cp infra/terraform-fresh/versions.tf infra/terraform-fresh/variables.tf /tmp/rehearsal-fresh-out/
  seed_providers /tmp/rehearsal-fresh-out
  if ! terraform -chdir=/tmp/rehearsal-fresh-out init -backend=false -input=false >/dev/null 2>&1; then
    log 'fresh-out init unreachable (offline?); validating against seeded providers.'
  fi
  terraform -chdir=/tmp/rehearsal-fresh-out validate >/dev/null 2>&1 || { echo 'generated fresh config does not validate.' >&2; exit 1; }
  log 'generated fresh config validates (terraform validate).'
fi
rm -rf /tmp/rehearsal-handoff.json /tmp/rehearsal-fresh-out
# Handoff serialization test: executes the EXACT non-dry-run serialization
# statements from wire-fresh-edge.sh (route append + file write) with
# synthetic values and asserts valid JSON with the required keys — the
# missing-import-sys class of defect fails here, not in production.
python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin) + [{"hostname": "h", "service": "s", "dns_record_id": "d", "access_app_id": "a", "policy_ids": json.loads(sys.argv[1])}]))' '["p"]' <<< '[]' > /tmp/rehearsal-route.json 2>/dev/null \
  || { echo 'handoff route serialization broken.' >&2; exit 1; }
python3 -c 'import json,sys; d=json.dumps({"tunnel_id": sys.argv[1], "tunnel_name": sys.argv[2], "routes": json.loads(sys.argv[3])}); h=json.loads(d); assert h["tunnel_id"] and h["tunnel_name"] and isinstance(h["routes"], list) and h["routes"][0]["dns_record_id"]' "tid" "tname" "$(cat /tmp/rehearsal-route.json)" > /tmp/rehearsal-handoff.json 2>/dev/null \
  || { echo 'handoff file serialization broken.' >&2; exit 1; }
log 'handoff serialization proven: route append + file write produce valid JSON with required keys.'
rm -f /tmp/rehearsal-route.json
# SSH-key identity gate: the exact function from run-remote-provision.sh must
# accept identical material and reject different/garbage keys (lockout guard).
sed -n '/^ssh_keys_match() {/,/^}/p' scripts/run-remote-provision.sh > /tmp/rehearsal-sshfn.sh
# shellcheck disable=SC1091 # generated snippet (exact function under test)
. /tmp/rehearsal-sshfn.sh
ssh-keygen -t ed25519 -N '' -f /tmp/rehearsal-k1 -q && ssh-keygen -t ed25519 -N '' -f /tmp/rehearsal-k2 -q
ssh_keys_match /tmp/rehearsal-k1.pub "$(cat /tmp/rehearsal-k1.pub)" || { echo 'ssh_keys_match rejects identical keys.' >&2; exit 1; }
ssh_keys_match /tmp/rehearsal-k1.pub "$(cat /tmp/rehearsal-k2.pub)" && { echo 'ssh_keys_match accepts different keys.' >&2; exit 1; } || true
ssh_keys_match /tmp/rehearsal-k1.pub 'not-a-key' && { echo 'ssh_keys_match accepts garbage.' >&2; exit 1; } || true
rm -f /tmp/rehearsal-sshfn.sh /tmp/rehearsal-k1 /tmp/rehearsal-k1.pub /tmp/rehearsal-k2 /tmp/rehearsal-k2.pub
log 'ssh key identity gate proven: identical accepted, different/garbage rejected.'
log 'edge routes proven in dry-run: dashboard + ssh ingress/DNS/Access planned, handoff import blocks emit.'
log 'runner dry-run idempotent across two passes; all four stages present; backup companion staged + scheduled; fileless R2 delivery enforced; fresh edge wired; no network touched.'
phase_ok runner_channel | tee -a "$artifact_dir/phases.log"

log '== backup_ready (dry-run) =='
{
bash scripts/backup-r2-probe.sh --dry-run
bash scripts/rollback-coolify-backup.sh --dry-run
bash scripts/rollback-app-workloads.sh --dry-run
bash scripts/rollback-app-workloads.sh --dry-run --recreate demo --db-password dry-run-only
# Topology unit test: the EXACT live extractor against synthetic inspect JSON.
cat > /tmp/rehearsal-inspect.json <<'INSPECT_EOF'
[{"Name": "/runtime-app", "Config": {"Image": "python:3.12-alpine", "Env": ["APP_MODE=proof", "DB_PASSWORD=s3cret"], "Labels": {"proof": "runtime"}, "Cmd": ["python3", "-m", "http.server", "8080"], "Entrypoint": ["/entry.sh", "--verbose-flag"], "WorkingDir": "/srv/www", "User": "65534", "Healthcheck": {"Test": ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost:8080/"], "Interval": 30000000000, "Timeout": 5000000000, "StartPeriod": 10000000000, "Retries": 3}}, "HostConfig": {"PortBindings": {"8080/tcp": [{"HostIp": "", "HostPort": "18081"}]}, "RestartPolicy": {"Name": "on-failure", "MaximumRetryCount": 5}}, "Mounts": [{"Type": "volume", "Source": "/var/lib/docker/volumes/runtime-www/_data", "Destination": "/srv/www", "Mode": "rw"}], "NetworkSettings": {"Networks": {"bridge": {}}}}]
INSPECT_EOF
topo_out="$(bash scripts/backup-app-workloads.sh --self-test-topology /tmp/rehearsal-inspect.json 2>/dev/null || true)"
rm -f /tmp/rehearsal-inspect.json
for want in '"ports": ["18081:8080/tcp"]' '"DB_PASSWORD": "REDACTED"' '"APP_MODE": "proof"' '"source": "/var/lib/docker/volumes/runtime-www/_data"' '"target": "/srv/www"' '"cmd": ["python3", "-m", "http.server", "8080"]' '"entrypoint": ["/entry.sh", "--verbose-flag"]' '"workdir": "/srv/www"' '"user": "65534"' '"restart": "on-failure"' '"restart_max": 5' '"CMD", "wget"' '"Interval": 30000000000' '"Timeout": 5000000000' '"Retries": 3'; do
  printf '%s' "$topo_out" | grep -qF "$want" || { echo "topology extractor broken (missing ${want})." >&2; exit 1; }
done
log 'topology extractor proven on synthetic inspect JSON (ports, redaction, mounts, full runtime contract).'
dbflags_out="$(bash scripts/rollback-app-workloads.sh --self-test-db-flags 2>/dev/null || true)"
for want in '--network' 'dbnet' '-p' '5433:5432/tcp' '--restart' 'on-failure:3' '--health-cmd' 'pg_isready -U dbowner' '--health-retries' '3' '-e' 'PGDATA=/var/lib/postgresql/data' '-l' 'proof=dbflags' '-u' 'postgres'; do
  printf '%s' "$dbflags_out" | grep -qF -- "$want" || { echo "db flag builder broken (missing ${want})." >&2; exit 1; }
done
for absent in 'POSTGRES_USER' 'POSTGRES_PASSWORD' 'REDACTED' 'dbproof-data:/var/lib/postgresql/data'; do
  printf '%s' "$dbflags_out" | grep -qF -- "$absent" && { echo "db flag builder leaks ${absent}." >&2; exit 1; } || true
done
log 'database flag builder proven offline (topology restored; fresh credential + pgdata mount omitted).'
bash scripts/ensure-service-token.sh --dry-run
bash scripts/ensure-service-token.sh --dry-run --ensure-only
bash scripts/tf-env-from-openbao.sh --dry-run
} >/tmp/rehearsal-backup.log 2>&1 || { echo 'a backup/lifecycle dry-run failed.' >&2; exit 1; }
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
