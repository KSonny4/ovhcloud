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
shellcheck scripts/bootstrap-vps.sh scripts/provision-coolify.sh scripts/configure-tunnel-access.sh scripts/backup-r2-probe.sh scripts/rehearse-fresh-environment.sh scripts/healthcheck.sh scripts/validate-repository.sh

git diff --check

if command -v terraform >/dev/null 2>&1; then
  terraform -chdir=infra/terraform fmt -check -recursive
  run_bounded 120 terraform -chdir=infra/terraform init -backend=false -input=false
  run_bounded 120 terraform -chdir=infra/terraform validate
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
