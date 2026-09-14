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
bash -n scripts/provision-coolify.sh
bash -n scripts/configure-tunnel-access.sh
bash -n scripts/backup-r2-probe.sh
bash -n scripts/rehearse-fresh-environment.sh
bash -n scripts/healthcheck.sh
bash -n scripts/run-remote-provision.sh
bash -n scripts/schedule-coolify-backup.sh
bash -n scripts/lib/preserved-guard.sh
bash -n scripts/ensure-service-token.sh
bash -n scripts/tf-env-from-openbao.sh
bash -n scripts/rollback-coolify-backup.sh
bash -n scripts/rollback-app-workloads.sh
bash -n scripts/backup-app-workloads.sh
bash -n scripts/ensure-tunnel.sh
bash -n scripts/test-clean-target-install.sh
bash -n scripts/wire-fresh-edge.sh
bash -n scripts/fetch-r2-env.sh
bash -n scripts/emit-fresh-imports.sh
bash -n scripts/adopt-fresh-edge.sh
shellcheck scripts/bootstrap-vps.sh scripts/provision-coolify.sh scripts/configure-tunnel-access.sh scripts/backup-r2-probe.sh scripts/rehearse-fresh-environment.sh scripts/healthcheck.sh scripts/validate-repository.sh scripts/run-remote-provision.sh scripts/schedule-coolify-backup.sh scripts/lib/preserved-guard.sh scripts/ensure-service-token.sh scripts/tf-env-from-openbao.sh scripts/rollback-coolify-backup.sh scripts/rollback-app-workloads.sh scripts/backup-app-workloads.sh scripts/ensure-tunnel.sh scripts/test-clean-target-install.sh scripts/wire-fresh-edge.sh scripts/fetch-r2-env.sh scripts/emit-fresh-imports.sh scripts/adopt-fresh-edge.sh

git diff --check

if command -v terraform >/dev/null 2>&1; then
  terraform -chdir=infra/terraform fmt -check -recursive
  # Hermetic init/validate in a disposable copy: initializing the live dir
  # would bind it to a backend (or poison it against ambient ~/.aws keys),
  # breaking every later credential-free gate run.
  gate_dir="$(mktemp -d)"
  trap 'rm -rf "$gate_dir"' EXIT
  cp infra/terraform/*.tf "$gate_dir/"
  run_bounded 120 terraform -chdir="$gate_dir" init -backend=false -input=false
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
