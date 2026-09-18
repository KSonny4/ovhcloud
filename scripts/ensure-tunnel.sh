#!/usr/bin/env bash
# Tunnel lifecycle (operator side, OpenBao-complete): ensure a DEDICATED
# Cloudflare Tunnel exists per fresh target, escrow its connector token at a
# per-target secret path BEFORE any consumer reads it, and stay a no-op when
# that path already holds one. OpenBao tunnel ontology (three entries,
# distinct roles, never mixed): EDGE_TUNNEL_SECRET.tunnel_secret feeds
# the preserved Terraform tunnel config via the loader; EDGE_TUNNEL_TOKEN.
# tunnel_token is the preserved connector's cold recovery escrow (no
# automation reads it); EDGE_TUNNEL_<NAME>.{tunnel_id,tunnel_token} is
# the per-target entry this script owns. The preserved entries are NEVER
# read or written here: a fresh target attaching to the preserved tunnel
# would inherit its routes, which the preservation boundary forbids.
#
# - Idempotent: an existing per-target tunnel_token wins (no-op).
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
#     TUNNEL_NAME=<name> TUNNEL_SECRET_PATH=<per-target-entry> \
#     bash scripts/ensure-tunnel.sh [--dry-run]
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
  log "DRY-RUN: read tunnel_token from OpenBao ${TUNNEL_SECRET_PATH:-<unset>}; create tunnel ${TUNNEL_NAME:-<unset>} via API + escrow {tunnel_id,tunnel_token} only when absent; fail closed otherwise"
  exit 0
fi
command -v bao >/dev/null 2>&1 || { echo 'bao CLI is required.' >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo 'curl is required.' >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo 'python3 is required.' >&2; exit 2; }
[ -n "${BAO_ADDR:-}" ] || { echo 'BAO_ADDR must be set.' >&2; exit 2; }
[ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ] || { echo 'CLOUDFLARE_ACCOUNT_ID must be set.' >&2; exit 2; }
[ -n "${TUNNEL_NAME:-}" ] || { echo 'TUNNEL_NAME must be set.' >&2; exit 2; }

secret_path="${TUNNEL_SECRET_PATH:?TUNNEL_SECRET_PATH (per-target OpenBao entry) must be set.}"
# Defense in depth (the runner refuses first): this script itself must never
# operate on the preserved tunnel or its escrow entries, no matter who
# invokes it.
if [ "${TUNNEL_NAME:-}" = 'nomad-admin' ]; then
  echo 'Refusing: nomad-admin is the preserved tunnel; fresh targets get a dedicated tunnel.' >&2
  exit 2
fi
case "$secret_path" in
  *nomad-admin*|EDGE_TUNNEL_TOKEN|EDGE_TUNNEL_SECRET)
    echo "Refusing: per-target path must not be a preserved entry (got ${secret_path})." >&2
    exit 2 ;;
esac
existing="$(bao kv get -field=tunnel_token "secret/projects/nomad/${secret_path}" 2>/dev/null || true)"
if [ -n "$existing" ]; then
  log "tunnel token already escrowed at ${secret_path}; no-op (value never printed)."
  exit 0
fi

log "no tunnel token escrowed; creating tunnel ${TUNNEL_NAME} via Cloudflare API."
admin="$(bao kv get -field=ADMIN_CLOUDFLARE secret/projects/nomad/ADMIN_CLOUDFLARE 2>/dev/null || true)"
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
if bao kv put -mount=secret "projects/nomad/${secret_path}" \
    "tunnel_id=${tunnel_id}" "tunnel_token=${tunnel_token}" >/dev/null 2>&1; then
  log "tunnel created + escrowed to OpenBao ${secret_path} (values never printed)."
else
  echo 'tunnel created but escrow failed; DELETE the orphan tunnel before retrying (fail closed).' >&2
  echo "orphan tunnel id: ${tunnel_id}" >&2
  exit 2
fi
tunnel_token=''
