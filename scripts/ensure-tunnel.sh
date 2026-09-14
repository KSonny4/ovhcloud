#!/usr/bin/env bash
# Tunnel lifecycle (operator side, OpenBao-complete): ensure a Cloudflare
# Tunnel exists for fresh provisioning, escrow its connector token BEFORE any
# consumer reads it, and stay a no-op when the escrow already holds one.
#
# - Idempotent: existing OpenBao COOLIFY_TUNNEL_TOKEN (tunnel_token) wins.
# - Creation uses the OpenBao-escrowed ADMIN_CLOUDFLARE token via the
#   Cloudflare API (create returns id + token); both are escrowed as
#   {tunnel_id, tunnel_token} before the runner consumes them.
# - Never prints secrets; fails closed on any API or escrow failure.
# - R2 S3 keys are intentionally NOT created here: token issuance returns
#   403/404 for this credential set, so R2 remains the single dashboard-gated
#   prerequisite (see docs/secret-rotation.md).
#
# Usage (operator machine):
#   BAO_ADDR=https://secrets.pkubelka.cz CLOUDFLARE_ACCOUNT_ID=<acct> \
#     TUNNEL_NAME=<name> bash scripts/ensure-tunnel.sh [--dry-run]
set -euo pipefail

dry_run=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    -h|--help) echo 'usage: ensure-tunnel.sh [--dry-run]'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '%s\n' "$*"; }
if [ "$dry_run" -eq 1 ]; then
  log "DRY-RUN: read tunnel_token from OpenBao COOLIFY_TUNNEL_TOKEN; create tunnel ${TUNNEL_NAME:-<unset>} via API + escrow {tunnel_id,tunnel_token} only when absent; fail closed otherwise"
  exit 0
fi
command -v bao >/dev/null 2>&1 || { echo 'bao CLI is required.' >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo 'curl is required.' >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo 'python3 is required.' >&2; exit 2; }
[ -n "${BAO_ADDR:-}" ] || { echo 'BAO_ADDR must be set.' >&2; exit 2; }
[ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ] || { echo 'CLOUDFLARE_ACCOUNT_ID must be set.' >&2; exit 2; }
[ -n "${TUNNEL_NAME:-}" ] || { echo 'TUNNEL_NAME must be set.' >&2; exit 2; }

existing="$(bao kv get -field=tunnel_token secret/projects/ovhcloud/COOLIFY_TUNNEL_TOKEN 2>/dev/null || true)"
if [ -n "$existing" ]; then
  log 'tunnel token already escrowed in OpenBao; no-op (value never printed).'
  exit 0
fi

log "no tunnel token escrowed; creating tunnel ${TUNNEL_NAME} via Cloudflare API."
admin="$(bao kv get -field=ADMIN_CLOUDFLARE secret/projects/ovhcloud/ADMIN_CLOUDFLARE 2>/dev/null || true)"
[ -n "$admin" ] || { echo 'ADMIN_CLOUDFLARE missing in OpenBao; cannot create tunnel.' >&2; exit 2; }
resp="$(mktemp)"; trap 'rm -f "$resp"' EXIT
code="$(curl -sS --max-time 30 -X POST \
  -H "Authorization: Bearer ${admin}" -H 'Content-Type: application/json' \
  -d "{\"name\":\"${TUNNEL_NAME}\",\"config_src\":\"cloudflare\"}" \
  "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel" \
  -o "$resp" -w '%{http_code}')"
admin=''
if [ "$code" != '200' ] && [ "$code" != '201' ]; then
  echo "tunnel creation failed: HTTP ${code} (fail closed). Body:" >&2
  python3 -c "import json; d=json.load(open('${resp}')); print(d.get('errors'))" >&2 || true
  exit 2
fi
tunnel_id="$(python3 -c "import json; print(json.load(open('${resp}')).get('result',{}).get('id',''))")"
tunnel_token="$(python3 -c "import json; print(json.load(open('${resp}')).get('result',{}).get('token',''))")"
rm -f "$resp"; trap - EXIT
if [ -z "$tunnel_id" ] || [ -z "$tunnel_token" ]; then
  echo 'tunnel creation returned no id/token (fail closed).' >&2
  exit 2
fi
if bao kv put -mount=secret projects/ovhcloud/COOLIFY_TUNNEL_TOKEN \
    "tunnel_id=${tunnel_id}" "tunnel_token=${tunnel_token}" >/dev/null 2>&1; then
  log 'tunnel created + escrowed to OpenBao COOLIFY_TUNNEL_TOKEN (values never printed).'
else
  echo 'tunnel created but escrow failed; DELETE the orphan tunnel before retrying (fail closed).' >&2
  echo "orphan tunnel id: ${tunnel_id}" >&2
  exit 2
fi
tunnel_token=''
