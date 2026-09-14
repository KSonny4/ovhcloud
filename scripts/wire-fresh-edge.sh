#!/usr/bin/env bash
# Fresh-edge wiring (operator side): connect a Tunnel identity to a hostname.
#
# Closes the fresh-path gap where a newly created tunnel has no hostname
# route: given a tunnel ID and a fully-qualified hostname, this script
# (all via the Cloudflare API with the OpenBao-escrowed ADMIN token):
#  1. sets the tunnel ingress config: <hostname> -> http://127.0.0.1:8000,
#     catch-all -> http404 (idempotent: fetched first, PUT only on drift);
#  2. creates/updates the DNS CNAME <hostname> -> <tunnel>.cfargotunnel.com
#     (proxied; idempotent by content);
#  3. verifies end to end: DNS resolves AND https://<hostname>/login returns
#     exactly HTTP 200 with the service-token pair (fail-closed, with
#     propagation retries).
#
# Never prints secrets; fails closed on any API drift or verification miss.
# Safe for the preserved hostname (pure no-op when DNS + ingress already
# match); refuses to delete or overwrite unrelated records.
#
# Usage (operator machine):
#   BAO_ADDR=... CLOUDFLARE_ACCOUNT_ID=... CLOUDFLARE_ZONE_ID=... \
#   TUNNEL_ID=<uuid> EDGE_HOSTNAME=<host> \
#   bash scripts/wire-fresh-edge.sh [--dry-run]
set -euo pipefail

dry_run=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    -h|--help) echo 'usage: wire-fresh-edge.sh [--dry-run]'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '%s\n' "$*"; }
for cmd in curl python3; do command -v "$cmd" >/dev/null 2>&1 || { echo "$cmd is required." >&2; exit 2; }; done
[ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ] || { echo 'CLOUDFLARE_ACCOUNT_ID must be set.' >&2; exit 2; }
[ -n "${CLOUDFLARE_ZONE_ID:-}" ] || { echo 'CLOUDFLARE_ZONE_ID must be set.' >&2; exit 2; }
[ -n "${TUNNEL_ID:-}" ] || { echo 'TUNNEL_ID must be set.' >&2; exit 2; }
[ -n "${EDGE_HOSTNAME:-}" ] || { echo 'EDGE_HOSTNAME must be set.' >&2; exit 2; }
if [ "$dry_run" -eq 0 ]; then
  command -v bao >/dev/null 2>&1 || { echo 'bao CLI is required.' >&2; exit 2; }
  [ -n "${BAO_ADDR:-}" ] || { echo 'BAO_ADDR must be set.' >&2; exit 2; }
fi

if [ "$dry_run" -eq 1 ]; then
  log "DRY-RUN: ingress ${EDGE_HOSTNAME} -> 127.0.0.1:8000 on tunnel ${TUNNEL_ID} (PUT only on drift)"
  log "DRY-RUN: DNS CNAME ${EDGE_HOSTNAME} -> ${TUNNEL_ID}.cfargotunnel.com (proxied, idempotent)"
  log 'DRY-RUN: verify DNS + HTTPS 200 with service token (propagation retries, fail closed)'
  exit 0
fi

admin="$(bao kv get -field=ADMIN_CLOUDFLARE secret/projects/ovhcloud/ADMIN_CLOUDFLARE 2>/dev/null || true)"
svc_id="$(bao kv get -field=client_id secret/projects/ovhcloud/COOLIFY_ACCESS_SERVICE_TOKEN 2>/dev/null || true)"
svc_secret="$(bao kv get -field=client_secret secret/projects/ovhcloud/COOLIFY_ACCESS_SERVICE_TOKEN 2>/dev/null || true)"
[ -n "$admin" ] && [ -n "$svc_id" ] && [ -n "$svc_secret" ] || { echo 'OpenBao escrow incomplete (admin + service-token pair required).' >&2; exit 2; }
api() { curl -sS --max-time 30 -H "Authorization: Bearer ${admin}" "$@"; }
acct="$CLOUDFLARE_ACCOUNT_ID"; zone="$CLOUDFLARE_ZONE_ID"; tid="$TUNNEL_ID"; host="$EDGE_HOSTNAME"

# --- 1. tunnel ingress (idempotent) ---
current_ingress="$(api "https://api.cloudflare.com/client/v4/accounts/${acct}/cfd_tunnel/${tid}/configurations" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get(\"result\",{}).get(\"config\",{}).get(\"ingress\",[])))' || true)"
if printf '%s' "$current_ingress" | python3 -c 'import json,sys; rules=json.load(sys.stdin); sys.exit(0 if any(r.get("hostname")=="'"${host}"'" and r.get("service")=="http://127.0.0.1:8000" for r in rules) else 1)'; then
  log 'ingress already routes the hostname; no PUT.'
else
  # Preserve existing rules, ensure ours is present and catch-all last.
  new_ingress="$(printf '%s' "$current_ingress" | python3 -c '
import json,sys
host = "'"${host}"'"
rules = [r for r in json.load(sys.stdin) if r.get("hostname") != host]
rules = [r for r in rules if "hostname" in r]
rules.append({"hostname": host, "service": "http://127.0.0.1:8000"})
rules.append({"service": "http_status:404"})
print(json.dumps({"config": {"ingress": rules}}))')"
  code="$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' -X PUT -H "Authorization: Bearer ${admin}" -H 'Content-Type: application/json' -d "$new_ingress" "https://api.cloudflare.com/client/v4/accounts/${acct}/cfd_tunnel/${tid}/configurations")"
  [ "$code" = '200' ] || { echo "ingress PUT failed: HTTP ${code} (fail closed)." >&2; exit 2; }
  log 'ingress updated for the hostname (existing rules preserved).'
fi

# --- 2. DNS CNAME (idempotent by content) ---
target="${tid}.cfargotunnel.com"
existing="$(api "https://api.cloudflare.com/client/v4/zones/${zone}/dns_records?type=CNAME&name=${host}" | python3 -c 'import json,sys; r=json.load(sys.stdin).get("result",[]); print((r[0].get("id","") + \" \" + r[0].get(\"content\",\"\")) if r else "")' || true)"
if [ "$existing" = "" ]; then
  code="$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer ${admin}" -H 'Content-Type: application/json' -d '{"type":"CNAME","name":"'"${host}"'","content":"'"${target}"'","ttl":1,"proxied":true}' "https://api.cloudflare.com/client/v4/zones/${zone}/dns_records")"
  { [ "$code" = '200' ] || [ "$code" = '201' ]; } || { echo "DNS create failed: HTTP ${code} (fail closed)." >&2; exit 2; }
  log "DNS CNAME created: ${host} -> ${target}."
else
  rec_content="${existing#* }"
  if [ "$rec_content" = "$target" ]; then
    log 'DNS CNAME already correct; no change.'
  else
    echo "DNS ${host} points at ${rec_content}, refusing to overwrite an unrelated record (fail closed)." >&2
    exit 2
  fi
fi

# --- 3. end-to-end verification (propagation retries, exactly 200) ---
admin=''
ok=0
for attempt in 1 2 3 4 5 6; do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --cookie-jar /dev/null --max-time 20 \
    -H "CF-Access-Client-Id: ${svc_id}" -H "CF-Access-Client-Secret: ${svc_secret}" \
    "https://${host}/login" 2>/dev/null || true)"
  if [ "$code" = '200' ]; then ok=1; break; fi
  log "attempt ${attempt}: HTTP ${code:-none} (waiting for propagation)..."
  sleep 20
done
svc_id=''; svc_secret=''
if [ "$ok" -eq 1 ]; then
  log "edge verified: https://${host}/login -> HTTP 200 on tunnel ${tid}."
else
  echo "edge verification failed after 6 attempts (required exactly 200)." >&2
  exit 1
fi
