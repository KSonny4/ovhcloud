#!/usr/bin/env bash
# Deploy jobs/control-panel.nomad.hcl without emptying any live secret.
#
# The job takes its secrets as HCL2 vars. A plain `nomad job run` from the
# file sends every unset var as "" and silently switches features off, so
# this script:
#   - reads GRAFANA_SERVICE_ACCOUNT_TOKEN from OpenBao (the escrowed source);
#   - carries every other secret over from the running job unchanged;
#   - passes values as NOMAD_VAR_* process env, never argv, never output;
#   - prints only which fields change (names, never values), then the plan;
#   - with --apply, runs the job (check-index guarded), then proves the
#     public origin answers through Cloudflare Access.
#
# Nomad listens on the VPS loopback only, so the script opens an SSH port
# forward for the duration of the run.
#
# Usage: bash scripts/deploy-control-panel.sh [--apply]
#   DEPLOY_SSH_TARGET   default ubuntu@148.113.245.89
#   DEPLOY_SSH_KEY      default ~/.ssh/ovh_coolify_ed25519
set -euo pipefail

apply=0
case "${1:-}" in
  --apply) apply=1 ;;
  ''|--plan) ;;
  -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
  *) echo "unknown argument: $1" >&2; exit 2 ;;
esac

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
job_file="$root_dir/jobs/control-panel.nomad.hcl"
target="${DEPLOY_SSH_TARGET:-ubuntu@148.113.245.89}"
key="${DEPLOY_SSH_KEY:-$HOME/.ssh/ovh_coolify_ed25519}"
export BAO_ADDR="${BAO_ADDR:-https://secrets.pkubelka.cz}"
for tool in bao nomad jq ssh curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool is required." >&2; exit 2; }
done
bao_field() { bao kv get -mount=secret -field="$1" "$2"; }

# var name -> task env name. Keep in sync with the job's env block.
vars=(
  cf_dns_api_token:CF_DNS_API_TOKEN
  cf_access_client_id:CF_ACCESS_CLIENT_ID
  cf_access_client_secret:CF_ACCESS_CLIENT_SECRET
  github_token:GITHUB_TOKEN
  grafana_sa_token:GRAFANA_SERVICE_ACCOUNT_TOKEN
  nomad_token:NOMAD_TOKEN
  ingest_token:CONTROL_INGEST_TOKEN
  unleash_admin_token:UNLEASH_ADMIN_TOKEN
  unleash_url:UNLEASH_URL
)

NOMAD_TOKEN="$(bao_field acl_token projects/nomad/NOMAD_BOOTSTRAP)"
export NOMAD_TOKEN
grafana_token="$(bao_field value projects/nomad/GRAFANA_SERVICE_ACCOUNT_TOKEN)"
[ -n "$grafana_token" ] || { echo 'OpenBao GRAFANA_SERVICE_ACCOUNT_TOKEN is empty; refusing.' >&2; exit 2; }
unleash_admin_token="$(bao_field admin_token projects/unleash/server)"
[ -n "$unleash_admin_token" ] || { echo 'OpenBao projects/unleash/server admin_token is empty; refusing.' >&2; exit 2; }

sock="$(mktemp -u "${TMPDIR:-/tmp}/cp-deploy.XXXXXX")"
local_port=$((20000 + RANDOM % 20000))
ssh -o ConnectTimeout=10 -o BatchMode=yes -o ExitOnForwardFailure=yes -i "$key" \
  -M -S "$sock" -f -N -L "127.0.0.1:${local_port}:127.0.0.1:4646" "$target"
trap 'ssh -S "$sock" -O exit "$target" >/dev/null 2>&1 || true' EXIT
export NOMAD_ADDR="http://127.0.0.1:${local_port}"

live="$(nomad job inspect control-panel)"
live_index="$(jq -r '.Job.JobModifyIndex' <<<"$live")"
echo "live job: version $(jq -r '.Job.Version' <<<"$live"), modify index $live_index"

for pair in "${vars[@]}"; do
  var="${pair%%:*}" env_name="${pair#*:}"
  value="$(jq -r --arg k "$env_name" '.Job.TaskGroups[].Tasks[] | select(.Name=="server") | .Env[$k] // ""' <<<"$live")"
  [ "$var" = grafana_sa_token ] && value="$grafana_token"
  [ "$var" = unleash_admin_token ] && value="$unleash_admin_token"
  [ "$var" = unleash_url ] && value="${value:-https://unleash.pkubelka.cz}"
  export "NOMAD_VAR_${var}=${value}"
done

rendered="$(nomad job run -output "$job_file")"
echo "changes from live (names only):"
jq -n -r --argjson a "$live" --argjson b "$rendered" '
  def tasks(j): [j.Job.TaskGroups[].Tasks[] | {key: .Name, value: .}] | from_entries;
  def ports(j): [j.Job.TaskGroups[].Networks[]? | (.ReservedPorts[]? | "\(.Label)=static:\(.Value)"), (.DynamicPorts[]? | "\(.Label)=dynamic")] | sort;
  (tasks($a)) as $ta | (tasks($b)) as $tb
  | ([ ($ta + $tb | keys[]) as $t
       | (if ($ta[$t].Config.image) != ($tb[$t].Config.image) then "  \($t): image" else empty end),
         (((($ta[$t].Env // {}) + ($tb[$t].Env // {})) | keys[]) as $k
          | if ($ta[$t].Env[$k]) != ($tb[$t].Env[$k]) then "  \($t): env \($k)" else empty end)
     ]
     + (if ports($a) != ports($b) then ["  ports: \(ports($a) | join(",")) -> \(ports($b) | join(","))"] else [] end))
  | if length == 0 then "  none" else .[] end'

echo "plan:"
nomad job plan -diff=false "$job_file" | sed -n '/^+\/- Job\|^+ Job\|Scheduler dry-run/,/^$/p' | sed 's/^/  /' || true

if [ "$apply" -eq 0 ]; then
  echo "plan only; rerun with --apply to deploy."
  exit 0
fi

nomad job run -check-index "$live_index" "$job_file" | sed 's/^/  /'

access_id="$(bao_field client_id projects/nomad/EDGE_ACCESS_SERVICE_TOKEN)"
access_secret="$(bao_field client_secret projects/nomad/EDGE_ACCESS_SERVICE_TOKEN)"
for attempt in 1 2 3 4 5 6; do
  code="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' \
    -H "CF-Access-Client-Id: $access_id" -H "CF-Access-Client-Secret: $access_secret" \
    https://control.pkubelka.cz/healthz || true)"
  echo "public /healthz: $code"
  [ "$code" = 200 ] && exit 0
  sleep 10
done
echo "control.pkubelka.cz did not answer 200; roll back with: nomad job revert control-panel <version>" >&2
exit 1
