#!/usr/bin/env bash
# Owner-run apply for the agent-reader Nomad ACL policy (#16, Slice N).
#
# What it does (only with --apply; --dry-run is the default and writes
# nothing):
#   1. `nomad acl policy apply agent-reader acl/agent-reader.policy.hcl`
#      (idempotent: re-applying the same rules is a no-op).
#   2. Mints one client token (name `agent-reader`, policy `agent-reader`)
#      with an expiration TTL from AGENT_READER_TTL (default `720h`).
#      Re-running mints a fresh token and replaces the escrow entry, i.e.
#      re-runs are safe rotations, not duplicates.
#   3. Escrows the token SecretID straight into Bao KV at
#      `secret/projects/nomad/AGENT_READ_TOKEN` (field `token`), piped on
#      stdin so the value is never printed, logged, echoed, or placed on a
#      command-line argument. Prints only the accessor ID and the Bao path.
#
# Prerequisites (caller-supplied; this script reads the management token
# from nowhere but its own environment):
#   NOMAD_ADDR / NOMAD_TOKEN (a management token), BAO_ADDR plus a Bao
#   session (e.g. `bao login`). The script never reads a token file.
#
# TTL caveat: Nomad's server-side `acl.token_max_expiration_ttl` defaults
# to 24h, so a 720h mint is REJECTED unless the server config raises it.
# The mint then fails and this script fails closed (set -e): lower
# AGENT_READER_TTL or raise the server limit, never fall back to a
# non-expiring token.
#
# Usage:
#   AGENT_READER_TTL=720h bash scripts/apply-agent-reader-acl.sh [--dry-run]
#   NOMAD_ADDR=... NOMAD_TOKEN=... BAO_ADDR=... bash scripts/apply-agent-reader-acl.sh --apply
set -euo pipefail

POLICY_NAME='agent-reader'
TOKEN_NAME='agent-reader'
BAO_MOUNT='secret'
BAO_PATH='projects/nomad/AGENT_READ_TOKEN'
BAO_FIELD='token'
FULL_BAO_PATH="secret/${BAO_PATH}"
TTL="${AGENT_READER_TTL:-720h}"

apply=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) apply=0; shift ;;
    --apply) apply=1; shift ;;
    -h|--help)
      echo 'usage: apply-agent-reader-acl.sh [--dry-run] [--apply]'
      echo '  --dry-run (default): print the plan, change nothing.'
      echo '  --apply: apply the policy, mint + escrow the token (needs NOMAD_ADDR/NOMAD_TOKEN/BAO_ADDR).'
      exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
policy_file="${repo_root}/acl/agent-reader.policy.hcl"
[ -f "$policy_file" ] || { echo "policy file missing: ${policy_file}" >&2; exit 2; }

if [ "$apply" -eq 0 ]; then
  echo 'DRY RUN: no writes. With --apply the script would:'
  echo "  1. nomad acl policy apply ${POLICY_NAME} ${policy_file}"
  echo "  2. nomad acl token create -name=${TOKEN_NAME} -policy=${POLICY_NAME} -type=client -ttl=${TTL} -json"
  echo "  3. pipe the SecretID into: bao kv put -mount=${BAO_MOUNT} ${BAO_PATH} ${BAO_FIELD}=-"
  echo "  4. print only the accessor ID and ${FULL_BAO_PATH}"
  echo "TTL source: AGENT_READER_TTL (current value: ${TTL})."
  echo 'Required for --apply: NOMAD_ADDR, NOMAD_TOKEN (management), BAO_ADDR + Bao session.'
  exit 0
fi

if [ -z "${NOMAD_ADDR:-}" ] || [ -z "${NOMAD_TOKEN:-}" ]; then
  echo 'NOMAD_ADDR and NOMAD_TOKEN (a management token) must be set in the environment.' >&2
  exit 2
fi
if [ -z "${BAO_ADDR:-}" ]; then
  echo 'BAO_ADDR must be set in the environment (plus a Bao session, e.g. via bao login).' >&2
  exit 2
fi
command -v nomad >/dev/null 2>&1 || { echo 'nomad CLI is required.' >&2; exit 2; }
command -v bao >/dev/null 2>&1 || { echo 'bao CLI is required.' >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo 'python3 is required to parse the mint output.' >&2; exit 2; }

export NOMAD_ADDR NOMAD_TOKEN BAO_ADDR

echo "applying Nomad ACL policy ${POLICY_NAME}..."
nomad acl policy apply "$POLICY_NAME" "$policy_file"

echo "minting client token ${TOKEN_NAME} (ttl ${TTL})..."
mint_json="$(nomad acl token create "-name=${TOKEN_NAME}" "-policy=${POLICY_NAME}" -type=client "-ttl=${TTL}" -json)"

accessor="$(printf '%s' "$mint_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessorID"])')"
if [ -z "$accessor" ]; then
  echo 'mint output had no AccessorID; the token was NOT escrowed (find it via nomad acl token list).' >&2
  exit 1
fi

# The SecretID travels memory-only: nomad stdout -> python on stdin ->
# bao on stdin. It never touches argv, stdout, or disk. If the escrow
# fails, fail closed and name the accessor so the owner can revoke the
# orphaned token (`nomad acl token delete <accessor>`).
if ! printf '%s' "$mint_json" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["SecretID"], end="")' \
  | bao kv put -mount="$BAO_MOUNT" "$BAO_PATH" "${BAO_FIELD}=-" >/dev/null; then
  echo "escrow to ${FULL_BAO_PATH} failed; revoking the orphaned token." >&2
  nomad acl token delete "$accessor" || echo "revoke failed: run \`nomad acl token delete ${accessor}\` manually." >&2
  exit 1
fi
mint_json=''

printf 'accessor: %s\nbao path: %s\n' "$accessor" "$FULL_BAO_PATH"
