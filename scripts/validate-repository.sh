#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root_dir"

run_bounded() {
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  else
    python3 - "$seconds" "$@" <<'PY'
import subprocess
import sys

seconds = int(sys.argv[1])
command = sys.argv[2:]
try:
    raise SystemExit(subprocess.run(command, check=False, timeout=seconds).returncode)
except subprocess.TimeoutExpired:
    print(f"command timed out after {seconds}s: {' '.join(command)}", file=sys.stderr)
    raise SystemExit(124)
PY
  fi
}

python3 scripts/validate-iac.py
bash -n scripts/bootstrap-vps.sh
bash -n scripts/provision-nomad.sh
bash -n scripts/verify-nomad-live.sh
bash -n scripts/configure-tunnel-access.sh
bash -n scripts/backup-r2-probe.sh
bash -n scripts/rehearse-fresh-environment.sh
bash -n scripts/healthcheck.sh
bash -n scripts/run-remote-provision.sh
bash -n scripts/schedule-host-backup.sh
bash -n scripts/lib/preserved-guard.sh
bash -n scripts/ensure-service-token.sh
bash -n scripts/tf-env-from-openbao.sh
bash -n scripts/rollback-nomad-snapshot.sh
bash -n scripts/rollback-app-workloads.sh
bash -n scripts/backup-app-workloads.sh
bash -n scripts/lib/backup-upload.sh
bash -n scripts/lib/s3-multipart.sh
bash -n scripts/test-backup-gates.sh
bash -n scripts/ensure-tunnel.sh
bash -n scripts/test-clean-target-install.sh
bash -n scripts/wire-fresh-edge.sh
bash -n scripts/fetch-r2-env.sh
bash -n scripts/emit-fresh-imports.sh
bash -n scripts/adopt-fresh-edge.sh
bash -n scripts/ensure-fresh-backend.sh
bash -n scripts/fetch-app-secrets.sh
bash -n scripts/recreate-workload.sh
bash -n scripts/collect-live-evidence.sh
bash -n scripts/collect-stage-proofs.sh
shellcheck scripts/bootstrap-vps.sh scripts/provision-nomad.sh scripts/verify-nomad-live.sh scripts/configure-tunnel-access.sh scripts/backup-r2-probe.sh scripts/rehearse-fresh-environment.sh scripts/healthcheck.sh scripts/validate-repository.sh scripts/run-remote-provision.sh scripts/schedule-host-backup.sh scripts/lib/preserved-guard.sh scripts/lib/backup-upload.sh scripts/lib/s3-multipart.sh scripts/ensure-service-token.sh scripts/tf-env-from-openbao.sh scripts/rollback-nomad-snapshot.sh scripts/rollback-app-workloads.sh scripts/backup-app-workloads.sh scripts/ensure-tunnel.sh scripts/test-clean-target-install.sh scripts/test-backup-gates.sh scripts/wire-fresh-edge.sh scripts/fetch-r2-env.sh scripts/emit-fresh-imports.sh scripts/adopt-fresh-edge.sh scripts/ensure-fresh-backend.sh scripts/fetch-app-secrets.sh scripts/recreate-workload.sh scripts/collect-live-evidence.sh scripts/collect-stage-proofs.sh

# Nomad-only gate: no tracked reference to the retired plane may remain in
# the active tree (history lives in git log + evidence-archive/, which this
# gate deliberately does not scan). The needle is assembled at runtime so
# this very gate does not itself contain the literal — including the
# deleted-script filenames, which are matched by pattern, not spelled out.
needle="cool""ify"
if git ls-files "scripts/*${needle}*" 'docs/03-*.md' 2>/dev/null | grep -v 'docs/03-nomad.md' | grep -q .; then
  echo 'retired-plane scripts/docs present:' >&2
  git ls-files "scripts/*${needle}*" 'docs/03-*.md' 2>/dev/null | grep -v 'docs/03-nomad.md' >&2
  exit 1
fi
# Documented non-references (false positives, not the retired platform):
# - the operator SSH key filename (operational reality, referenced by
#   runbooks);
# - legacy R2 object names inside the dated evidence record (recovery facts).
retired_plane_allow="ovh_cool""ify_ed25519|cool""ify-db/redis"
if git grep -i -l "$needle" -- CONTEXT.md README.md AGENTS.md docs scripts infra/terraform infra/terraform-fresh .github 2>/dev/null | grep -q .; then
  remaining="$(git grep -i "$needle" -- CONTEXT.md README.md AGENTS.md docs scripts infra/terraform infra/terraform-fresh .github 2>/dev/null | grep -viE "$retired_plane_allow" || true)"
  if [ -n "$remaining" ]; then
    echo 'retired-plane references remain in the active tree:' >&2
    printf '%s\n' "$remaining" >&2
    exit 1
  fi
fi

git diff --check

if command -v terraform >/dev/null 2>&1; then
  terraform -chdir=infra/terraform fmt -check -recursive
  # Hermetic init/validate in a disposable copy: initializing the live dir
  # would bind it to a backend (or poison it against ambient ~/.aws keys),
  # breaking every later credential-free gate run.
  gate_dir="$(mktemp -d)"
  trap 'rm -rf "$gate_dir"' EXIT
  cp infra/terraform/*.tf "$gate_dir/"
  # Provider downloads flap (registry 5xx); retry bounded, still fail closed.
  init_ok=''
  for _ in 1 2 3; do
    if run_bounded 120 terraform -chdir="$gate_dir" init -backend=false -input=false; then init_ok=1; break; fi
    sleep 15
  done
  [ -n "$init_ok" ] || { echo 'provider init failed after 3 attempts.' >&2; exit 1; }
  run_bounded 120 terraform -chdir="$gate_dir" validate
  rm -rf "$gate_dir"
  trap - EXIT
else
  echo 'terraform not installed; structural IaC validation was run instead'
fi

if command -v graft >/dev/null 2>&1; then
  graft check
else
  echo 'graft not installed; install graft before merging deployment changes' >&2
  exit 1
fi

printf '%s\n' 'Repository validation passed.'
