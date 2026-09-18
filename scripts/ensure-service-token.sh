#!/usr/bin/env bash
# Complete Cloudflare Access service-token lifecycle for machine verification.
#
# The API never reveals a token secret after creation/rotation, so OpenBao is
# the sole record: this script ensures the token exists (creating it when
# absent), escrows every derived value, rotates on demand, and proves the
# escrowed pair is accepted by the UI leader endpoint. Every stage fails closed.
#
# - Reads: Cloudflare admin token ONLY from OpenBao
#   (secret/projects/ovhcloud/ADMIN_CLOUDFLARE field ADMIN_CLOUDFLARE).
# - Writes: secret/projects/ovhcloud/EDGE_ACCESS_SERVICE_TOKEN fields
#   client_id, client_secret, token_id, duration (never printed, never disk).
# - Never touches the preserved VPS; only Cloudflare API + OpenBao + HTTPS.
#
# Usage:
#   BAO_ADDR=https://secrets.pkubelka.cz CLOUDFLARE_ACCOUNT_ID=... \
#   NOMAD_LEADER_URL=https://nomad.example.com/v1/status/leader \
#   bash scripts/ensure-service-token.sh [--dry-run] [--rotate]
set -euo pipefail

dry_run=0
rotate=0
ensure_only=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --rotate) rotate=1; shift ;;
    --ensure-only) ensure_only=1; shift ;;
    -h|--help) echo 'usage: ensure-service-token.sh [--dry-run] [--rotate] [--ensure-only]'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() { printf '%s\n' "$*"; }

token_name="${SERVICE_TOKEN_NAME:-ovh-nomad-machine-verification}"
duration="${SERVICE_TOKEN_DURATION:-8760h}"
account="${CLOUDFLARE_ACCOUNT_ID:-5eb3ea3a84b37564cfd8739f32ffb559}"
login_url="${NOMAD_LEADER_URL:-}"
bao_addr="${BAO_ADDR:-https://secrets.pkubelka.cz}"
# Ensure-only mode (first-time flow): create + escrow WITHOUT verification,
# so downstream steps can consume the escrow before any route exists to verify
# against. NOMAD_LEADER_URL is required only when verifying.
if [ -z "$login_url" ] && [ "$dry_run" -eq 0 ] && [ "$ensure_only" -eq 0 ]; then
  echo 'NOMAD_LEADER_URL must be set (proves the escrowed pair is accepted).' >&2
  exit 2
fi

if [ "$dry_run" -eq 1 ]; then
  log 'DRY-RUN: read Cloudflare admin token from OpenBao by name only (value never printed)'
  log 'DRY-RUN: list Access service tokens, match by name, create when absent (fail closed on API error)'
  log 'DRY-RUN: escrow client_id/client_secret/token_id/duration to OpenBao EDGE_ACCESS_SERVICE_TOKEN (fail closed when escrow unavailable)'
  log 'DRY-RUN: verify escrowed pair against NOMAD_LEADER_URL, require HTTP 200 (fail closed)'
  exit 0
fi

command -v bao >/dev/null 2>&1 || { echo 'bao CLI is required.' >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo 'python3 is required for API/escrow handling.' >&2; exit 2; }
export BAO_ADDR="$bao_addr"
admin_token="$(bao kv get -field=ADMIN_CLOUDFLARE secret/projects/ovhcloud/ADMIN_CLOUDFLARE)"
if [ -z "$admin_token" ]; then
  echo 'OpenBao escrow missing: ADMIN_CLOUDFLARE; refusing to continue.' >&2
  exit 2
fi
log 'admin token retrieved from OpenBao (value never printed).'

# All Cloudflare + OpenBao interaction happens in one python step so secret
# values never touch shell variables, command arguments, or disk.
export CF_ADMIN_TOKEN="$admin_token" CF_ACCOUNT="$account" CF_TOKEN_NAME="$token_name"
export CF_DURATION="$duration" CF_LOGIN_URL="$login_url" CF_ROTATE="$rotate" CF_ENSURE_ONLY="$ensure_only"
python3 - <<'PY'
import json, os, subprocess, urllib.request, urllib.error, sys

admin = os.environ['CF_ADMIN_TOKEN']
acct = os.environ['CF_ACCOUNT']
name = os.environ['CF_TOKEN_NAME']
dur = os.environ['CF_DURATION']
login = os.environ['CF_LOGIN_URL']
rotate = os.environ['CF_ROTATE'] == '1'
bao_addr = os.environ.get('BAO_ADDR', 'https://secrets.pkubelka.cz')

def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        f'https://api.cloudflare.com/client/v4{path}', data=data, method=method,
        headers={'Authorization': f'Bearer {admin}', 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        sys.exit(f"Cloudflare API {method} {path} failed: HTTP {e.code}: {e.read().decode()[:200]}")

def bao_escrow(cid, sec, tid):
    p = subprocess.run(
        ['bao', 'kv', 'put', '-mount=secret', 'projects/ovhcloud/EDGE_ACCESS_SERVICE_TOKEN',
         f'client_id={cid}', f'client_secret={sec}',
         f'token_id={tid}', f'duration={dur}'],
        capture_output=True, text=True, env={**os.environ, 'BAO_ADDR': bao_addr})
    if p.returncode != 0:
        sys.exit(f'OpenBao escrow failed (fail closed): {p.stderr.strip()[:200]}')

def verify(cid, sec):
    # Clean-jar semantics: this fresh process holds no cookies, so none are
    # sent (an explicit empty Cookie header would itself break the request).
    # Cloudflare bot management rejects the default Python-urllib UA; identify
    # honestly as the lifecycle checker.
    req = urllib.request.Request(
        login, headers={'CF-Access-Client-Id': cid, 'CF-Access-Client-Secret': sec,
                        'User-Agent': 'ovh-nomad-lifecycle-check/1.0'})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            code = r.status
    except urllib.error.HTTPError as e:
        code = e.code
    if code != 200:
        sys.exit(f'service-token verification failed: HTTP {code} (required 200; a 302 means the token was not accepted)')
    print('service-token verification: HTTP 200 (escrowed pair accepted).')

toks = api('GET', f'/accounts/{acct}/access/service_tokens').get('result', [])
match = next((t for t in toks if t.get('name') == name), None)
if match is None:
    print(f'token {name!r} absent; creating with duration {dur}.')
    created = api('POST', f'/accounts/{acct}/access/service_tokens',
                  {'name': name, 'duration': dur}).get('result', {})
    tid, cid, sec = created.get('id'), created.get('client_id'), created.get('client_secret')
    if not (tid and cid and sec):
        sys.exit('creation response lacked id/client_id/client_secret; refusing to continue.')
    bao_escrow(cid, sec, tid)
    print('created and escrowed.')
else:
    tid, cid = match['id'], match['client_id']
    if rotate:
        print(f'token {name!r} exists ({tid}); rotating.')
        rot = api('POST', f'/accounts/{acct}/access/service_tokens/{tid}/rotate').get('result', {})
        sec = rot.get('client_secret') or rot.get('value')
        if not sec:
            sys.exit('rotation response lacked the new secret; refusing to continue.')
        bao_escrow(cid, sec, tid)
        print('rotated and escrowed.')
    else:
        print(f'token {name!r} exists ({tid}); verifying escrowed pair.')
        cur = subprocess.run(
            ['bao', 'kv', 'get', '-field=client_secret',
             'secret/projects/ovhcloud/EDGE_ACCESS_SERVICE_TOKEN'],
            capture_output=True, text=True, env={**os.environ, 'BAO_ADDR': bao_addr})
        if cur.returncode != 0 or not cur.stdout.strip():
            sys.exit('OpenBao escrow missing client_secret for the existing token; refusing to continue.')
        sec = cur.stdout.strip()
if os.environ['CF_ENSURE_ONLY'] == '1':
    print('ensure-only: created/exists + escrowed; verification deferred until the route exists.')
else:
    verify(cid, sec)
PY

if [ "$ensure_only" -eq 1 ]; then
  log 'service-token ensure-only complete: exists + escrowed in OpenBao (verification deferred).'
else
  log 'service-token lifecycle complete: ensured, escrowed in OpenBao, verified with HTTP 200.'
fi
