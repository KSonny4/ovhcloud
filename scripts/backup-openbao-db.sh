#!/usr/bin/env bash
# Shell entrypoint installed beside the host-backup timer.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
exec python3 "${script_dir}/backup-openbao-db.py" "$@"
