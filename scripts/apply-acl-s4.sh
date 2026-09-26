#!/usr/bin/env bash
# Owner-run apply for the Slice 4 Nomad ACL (KSonny4/platform#26).
#
# What it does (only with --apply; --dry-run is the default and writes
# nothing):
#   1. `nomad namespace apply acl/namespace-sandbox.hcl`
#      (idempotent: re-applying the same spec is a no-op).
#   2. `nomad acl policy apply deployer acl/deployer.policy.hcl`
#      `nomad acl policy apply agent-sandbox acl/agent-sandbox.policy.hcl`
#      (idempotent: re-applying the same rules is a no-op).
#   3. Mints two client tokens with expiration TTLs from WATCHER_DEPLOY_TTL
#      / AGENT_SANDBOX_TTL (default `720h` each):
#        - name `watcher-deployer`, policy `deployer`
#        - name `agent-sandbox`, policy `agent-sandbox`
#      Re-running mints fresh tokens and replaces the escrow entries, i.e.
#      re-runs are safe rotations, not duplicates.
#   4. Escrows each token SecretID straight into Bao KV, piped on stdin so
#      the value is never printed, logged, echoed, or placed on a
#      command-line argument. Prints only accessor IDs and Bao paths:
#        - `secret/projects/nomad/WATCHER_DEPLOY_TOKEN` (field `token`)
#        - `secret/projects/nomad/AGENT_SANDBOX_TOKEN` (field `token`)
#
# Namespace names are data, not hard-coded here: they are read from
# acl/namespaces.json and cross-checked against the policy files before
# anything is applied (the same check the contract test enforces).
#
# Prerequisites (caller-supplied; this script reads the management token
# from nowhere but its own environment):
#   NOMAD_ADDR / NOMAD_TOKEN (a management token), BAO_ADDR plus a Bao
#   session (e.g. `bao login`). The script never reads a token file.
#
# TTL caveat: Nomad's server-side `acl.token_max_expiration_ttl` defaults
# to 24h, so a 720h mint is REJECTED unless the server config raises it.
# The mint then fails and this script fails closed (set -e): lower the TTL
# or raise the server limit, never fall back to a non-expiring token.
#
# Usage:
#   WATCHER_DEPLOY_TTL=720h AGENT_SANDBOX_TTL=720h bash scripts/apply-acl-s4.sh [--dry-run]
#   NOMAD_ADDR=... NOMAD_TOKEN=... BAO_ADDR=... bash scripts/apply-acl-s4.sh --apply
set -euo pipefail

BAO_MOUNT='secret'
WATCHER_BAO_PATH='projects/nomad/WATCHER_DEPLOY_TOKEN'
SANDBOX_BAO_PATH='projects/nomad/AGENT_SANDBOX_TOKEN'
BAO_FIELD='token'
WATCHER_TTL="${WATCHER_DEPLOY_TTL:-720h}"
SANDBOX_TTL="${AGENT_SANDBOX_TTL:-720h}"

apply=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) apply=0; shift ;;
    --apply) apply=1; shift ;;
    -h|--help)
      echo 'usage: apply-acl-s4.sh [--dry-run] [--apply]'
      echo '  --dry-run (default): print the plan, change nothing.'
      echo '  --apply: apply namespace + policies, mint + escrow tokens (needs NOMAD_ADDR/NOMAD_TOKEN/BAO_ADDR).'
      exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
data_file="${repo_root}/acl/namespaces.json"
namespace_spec="${repo_root}/acl/namespace-sandbox.hcl"
deployer_policy="${repo_root}/acl/deployer.policy.hcl"
sandbox_policy="${repo_root}/acl/agent-sandbox.policy.hcl"
for f in "$data_file" "$namespace_spec" "$deployer_policy" "$sandbox_policy"; do
  [ -f "$f" ] || { echo "required file missing: ${f}" >&2; exit 2; }
done

# Resolve namespace names from the data file (python3 only parses; the
# values below are echoed, never secret).
namespaces="$(python3 - "$data_file" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
print(" ".join(data["production"]))
print(data["sandbox"])
PY
)"
production_namespaces="$(printf '%s' "$namespaces" | sed -n '1p')"
sandbox_namespace="$(printf '%s' "$namespaces" | sed -n '2p')"

# Preflight: every namespace block label in each policy must come from the
# data file (production list for deployer, sandbox only for agent-sandbox).
check_policy_namespaces() {
  policy_file="$1"
  allowed="$2"
  labels="$(grep -oE '^[[:space:]]*namespace +"[^"]+"' "$policy_file" | grep -oE '"[^"]+"' | tr -d '"' || true)"
  for label in $labels; do
    case " $allowed " in
      *" $label "*) ;;
      *) echo "policy $(basename "$policy_file") references namespace '${label}' not in [${allowed}] (acl/namespaces.json)" >&2; exit 2 ;;
    esac
  done
}
check_policy_namespaces "$deployer_policy" "$production_namespaces"
check_policy_namespaces "$sandbox_policy" "$sandbox_namespace"

if [ "$apply" -eq 0 ]; then
  echo 'DRY RUN: no writes. With --apply the script would:'
  echo "  1. nomad namespace apply ${namespace_spec} (namespace: ${sandbox_namespace})"
  echo "  2. nomad acl policy apply deployer ${deployer_policy} (namespaces: ${production_namespaces})"
  echo "  3. nomad acl policy apply agent-sandbox ${sandbox_policy} (namespace: ${sandbox_namespace})"
  echo "  4. nomad acl token create -name=watcher-deployer -policy=deployer -type=client -ttl=${WATCHER_TTL} -json"
  echo "  5. pipe the SecretID into: bao kv put -mount=${BAO_MOUNT} ${WATCHER_BAO_PATH} ${BAO_FIELD}=-"
  echo "  6. nomad acl token create -name=agent-sandbox -policy=agent-sandbox -type=client -ttl=${SANDBOX_TTL} -json"
  echo "  7. pipe the SecretID into: bao kv put -mount=${BAO_MOUNT} ${SANDBOX_BAO_PATH} ${BAO_FIELD}=-"
  echo "  8. print only accessor IDs and the two Bao paths."
  echo "TTL sources: WATCHER_DEPLOY_TTL (current: ${WATCHER_TTL}), AGENT_SANDBOX_TTL (current: ${SANDBOX_TTL})."
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

mint_and_escrow() {
  token_name="$1"
  policy_name="$2"
  ttl="$3"
  bao_path="$4"
  full_bao_path="secret/${bao_path}"
  echo "minting client token ${token_name} (ttl ${ttl})..."
  mint_json="$(nomad acl token create "-name=${token_name}" "-policy=${policy_name}" -type=client "-ttl=${ttl}" -json)"
  accessor="$(printf '%s' "$mint_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessorID"])')"
  if [ -z "$accessor" ]; then
    echo "mint output for ${token_name} had no AccessorID; the token was NOT escrowed (find it via nomad acl token list)." >&2
    exit 1
  fi
  # The SecretID travels memory-only: nomad stdout -> python on stdin ->
  # bao on stdin. It never touches argv, stdout, or disk. If the escrow
  # fails, fail closed and name the accessor so the owner can revoke the
  # orphaned token (`nomad acl token delete <accessor>`).
  if ! printf '%s' "$mint_json" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["SecretID"], end="")' \
    | bao kv put -mount="$BAO_MOUNT" "$bao_path" "${BAO_FIELD}=-" >/dev/null; then
    echo "escrow to ${full_bao_path} failed; revoking the orphaned token." >&2
    nomad acl token delete "$accessor" || echo "revoke failed: run \`nomad acl token delete ${accessor}\` manually." >&2
    exit 1
  fi
  mint_json=''
  printf 'accessor: %s\nbao path: %s\n' "$accessor" "$full_bao_path"
}

echo "applying Nomad namespace ${sandbox_namespace}..."
nomad namespace apply "$namespace_spec"

echo 'applying Nomad ACL policy deployer...'
nomad acl policy apply deployer "$deployer_policy"

echo 'applying Nomad ACL policy agent-sandbox...'
nomad acl policy apply agent-sandbox "$sandbox_policy"

mint_and_escrow watcher-deployer deployer "$WATCHER_TTL" "$WATCHER_BAO_PATH"
mint_and_escrow agent-sandbox agent-sandbox "$SANDBOX_TTL" "$SANDBOX_BAO_PATH"
