#!/usr/bin/env bash
# Fresh-edge wiring (operator side): connect a Tunnel identity to hostnames.
#
# Closes the fresh-path gap where a newly created tunnel has no hostname
# routes: given a tunnel ID, the dashboard hostname (required) and the SSH
# hostname (optional but wired by the runner for every fresh zone), this
# script (all via the Cloudflare API with the OpenBao-escrowed ADMIN token):
#  1. sets tunnel ingress: dashboard -> http://127.0.0.1:8000,
#     ssh -> ssh://localhost:22, catch-all -> http_status:404
#     (idempotent: fetched first, PUT only on drift, existing rules kept);
#  2. creates the DNS CNAMEs <host> -> <tunnel>.cfargotunnel.com, proxied,
#     idempotent by content (refuses to overwrite unrelated records);
#  3. ensures a self-hosted Access app + two policies (machine service token
#     precedence 1, ksonny4@gmail.com precedence 2, OTP IdP, 24h session —
#     mirroring the preserved apps) for each hostname;
#  4. verifies end to end with propagation retries (fail closed):
#     dashboard https://<host>/login -> exactly HTTP 200 with the
#     service-token pair; ssh https://<host> -> a gated status
#     (301/302/401/403: route live and policy-gated, no token needed).
#
# With --handoff-file PATH, writes machine-readable IDs (tunnel, DNS records,
# Access apps/policies) for the Terraform import handoff
# (scripts/emit-fresh-imports.sh). Never prints secrets.
#
# Usage (operator machine):
#   BAO_ADDR=... CLOUDFLARE_ACCOUNT_ID=... CLOUDFLARE_ZONE_ID=... \
#   TUNNEL_ID=<uuid> EDGE_HOSTNAME=<dash-host> [SSH_HOSTNAME=<ssh-host>] \
#   bash scripts/wire-fresh-edge.sh [--dry-run] [--handoff-file PATH]
set -euo pipefail

dry_run=0
handoff_file=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --handoff-file) handoff_file="$2"; shift 2 ;;
    --handoff-file=*) handoff_file="${1#--handoff-file=}"; shift ;;
    -h|--help) echo 'usage: wire-fresh-edge.sh [--dry-run] [--handoff-file PATH]'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
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

hostnames="$EDGE_HOSTNAME"
[ -n "${SSH_HOSTNAME:-}" ] && hostnames="$hostnames $SSH_HOSTNAME"
service_for() {
  if [ "$1" = "$EDGE_HOSTNAME" ]; then printf 'http://127.0.0.1:8000'; else printf 'ssh://localhost:22'; fi
}

if [ "$dry_run" -eq 1 ]; then
  for host in $hostnames; do
    log "DRY-RUN: ingress ${host} -> $(service_for "$host") on tunnel ${TUNNEL_ID} (PUT only on drift)"
    log "DRY-RUN: DNS CNAME ${host} -> ${TUNNEL_ID}.cfargotunnel.com (proxied, idempotent)"
    log "DRY-RUN: ensure Access app + service-token/email policies for ${host}"
  done
  log 'DRY-RUN: verify dashboard 200 with service token + ssh gated status (propagation retries, fail closed)'
  [ -n "$handoff_file" ] && log "DRY-RUN: write handoff JSON to ${handoff_file}"
  exit 0
fi

admin="$(bao kv get -field=ADMIN_CLOUDFLARE secret/projects/ovhcloud/ADMIN_CLOUDFLARE 2>/dev/null || true)"
svc_id="$(bao kv get -field=client_id secret/projects/ovhcloud/COOLIFY_ACCESS_SERVICE_TOKEN 2>/dev/null || true)"
svc_secret="$(bao kv get -field=client_secret secret/projects/ovhcloud/COOLIFY_ACCESS_SERVICE_TOKEN 2>/dev/null || true)"
svc_token_id="$(bao kv get -field=token_id secret/projects/ovhcloud/COOLIFY_ACCESS_SERVICE_TOKEN 2>/dev/null || true)"
[ -n "$admin" ] && [ -n "$svc_id" ] && [ -n "$svc_secret" ] && [ -n "$svc_token_id" ] || { echo 'OpenBao escrow incomplete (admin + service-token triple required).' >&2; exit 2; }
api() { curl -sS --max-time 30 -H "Authorization: Bearer ${admin}" "$@"; }
apost() { curl -sS --max-time 30 -X POST -H "Authorization: Bearer ${admin}" -H 'Content-Type: application/json' "$@"; }
acct="$CLOUDFLARE_ACCOUNT_ID"; zone="$CLOUDFLARE_ZONE_ID"; tid="$TUNNEL_ID"
target="${tid}.cfargotunnel.com"
handoff_routes='[]'

otp_uid="$(api "https://api.cloudflare.com/client/v4/accounts/${acct}/access/identity_providers" | python3 -c 'import json,sys; print(next((i["id"] for i in json.load(sys.stdin).get("result",[]) if i.get("type")=="onetimepin"),""))')"
[ -n "$otp_uid" ] || { echo 'OTP identity provider not found in account (fail closed).' >&2; exit 2; }

# --- 1. tunnel ingress, all routes at once (idempotent) ---
wanted="$(for host in $hostnames; do printf '%s=%s\n' "$host" "$(service_for "$host")"; done)"
current_ingress="$(api "https://api.cloudflare.com/client/v4/accounts/${acct}/cfd_tunnel/${tid}/configurations" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get("result",{}).get("config",{}).get("ingress",[]))))' 2>/dev/null || echo '[]')"
if printf '%s\n%s' "$current_ingress" "$wanted" | python3 -c '
import json,sys
raw = sys.stdin.read().rsplit("\n[",1)
rules = json.loads("[" + raw[1]) if len(raw) > 1 else []
want = dict(l.split("=",1) for l in raw[0].strip().split("\n") if "=" in l)
sys.exit(0 if all(any(r.get("hostname")==h and r.get("service")==s for r in rules) for h,s in want.items()) else 1)'; then
  log 'ingress already routes all hostnames; no PUT.'
else
  new_ingress="$(printf '%s\n%s' "$current_ingress" "$wanted" | python3 -c '
import json,sys
raw = sys.stdin.read().rsplit("\n[",1)
rules = [r for r in (json.loads("[" + raw[1]) if len(raw) > 1 else []) if "hostname" in r]
want = dict(l.split("=",1) for l in raw[0].strip().split("\n") if "=" in l)
have = {r["hostname"] for r in rules}
for h,s in want.items():
    if h not in have:
        rules.append({"hostname": h, "service": s})
rules.append({"service": "http_status:404"})
print(json.dumps({"config": {"ingress": rules}}))')"
  code="$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' -X PUT -H "Authorization: Bearer ${admin}" -H 'Content-Type: application/json' -d "$new_ingress" "https://api.cloudflare.com/client/v4/accounts/${acct}/cfd_tunnel/${tid}/configurations")"
  [ "$code" = '200' ] || { echo "ingress PUT failed: HTTP ${code} (fail closed)." >&2; exit 2; }
  log 'ingress updated for all hostnames (existing rules preserved).'
fi

# --- 2+3. per-hostname DNS + Access app/policies ---
for host in $hostnames; do
  existing="$(api "https://api.cloudflare.com/client/v4/zones/${zone}/dns_records?type=CNAME&name=${host}" | python3 -c 'import json,sys; r=json.load(sys.stdin).get("result",[]); print((r[0].get("id","") + " " + r[0].get("content","")) if r else "")' || true)"
  dns_id=''
  if [ "$existing" = "" ]; then
    resp="$(mktemp)"; trap 'rm -f "$resp"' EXIT
    code="$(curl -sS --max-time 30 -o "$resp" -w '%{http_code}' -X POST -H "Authorization: Bearer ${admin}" -H 'Content-Type: application/json' -d '{"type":"CNAME","name":"'"${host}"'","content":"'"${target}"'","ttl":1,"proxied":true}' "https://api.cloudflare.com/client/v4/zones/${zone}/dns_records")"
    { [ "$code" = '200' ] || [ "$code" = '201' ]; } || { echo "DNS create failed for ${host}: HTTP ${code}." >&2; exit 2; }
    dns_id="$(python3 -c 'import json; print(json.load(open("'"${resp}"'")).get("result",{}).get("id",""))')"
    rm -f "$resp"; trap - EXIT
    log "DNS CNAME created: ${host} -> ${target}."
  else
    dns_id="${existing%% *}"; rec_content="${existing#* }"
    if [ "$rec_content" = "$target" ]; then
      log "DNS CNAME already correct for ${host}; no change."
    else
      echo "DNS ${host} points at ${rec_content}, refusing to overwrite an unrelated record (fail closed)." >&2
      exit 2
    fi
  fi
  # Access app (idempotent by domain) + two policies (idempotent by name).
  if [ "$host" = "$EDGE_HOSTNAME" ]; then app_name="Coolify Dashboard"; else app_name="Coolify SSH Administration"; fi
  app_id="$(api "https://api.cloudflare.com/client/v4/accounts/${acct}/access/apps?domain=${host}" | python3 -c 'import json,sys; r=json.load(sys.stdin).get("result",[]); print(r[0].get("id","") if r else "")')"
  if [ -z "$app_id" ]; then
    app_id="$(apost -d '{"name":"'"${app_name}"'","domain":"'"${host}"'","type":"self_hosted","session_duration":"24h","auto_redirect_to_identity":false,"allowed_idps":["'"${otp_uid}"'"],"enable_binding_cookie":true}' "https://api.cloudflare.com/client/v4/accounts/${acct}/access/apps" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("result",{}).get("id",""))')"
    [ -n "$app_id" ] || { echo "Access app creation failed for ${host} (fail closed)." >&2; exit 2; }
    log "Access app created for ${host}."
  else
    log "Access app already exists for ${host}; no change."
  fi
  policy_ids='[]'
  for pname in 'Allow machine service token' 'Allow ksonny4@gmail.com'; do
    pid="$(api "https://api.cloudflare.com/client/v4/accounts/${acct}/access/apps/${app_id}/policies" | python3 -c 'import json,sys; print(next((p["id"] for p in json.load(sys.stdin).get("result",[]) if p.get("name")=="'"${pname}"'"),""))')"
    if [ -z "$pid" ]; then
      if [ "$pname" = 'Allow machine service token' ]; then
        include='[{"service_token":{"token_id":"'"${svc_token_id}"'"}}]'; prec=1
      else
        include='[{"email":{"email":"ksonny4@gmail.com"}}]'; prec=2
      fi
      pid="$(apost -d '{"name":"'"${pname}"'","decision":"allow","precedence":'"${prec}"',"include":'"${include}"'}' "https://api.cloudflare.com/client/v4/accounts/${acct}/access/apps/${app_id}/policies" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("result",{}).get("id",""))')"
      [ -n "$pid" ] || { echo "Access policy ${pname} creation failed for ${host} (fail closed)." >&2; exit 2; }
      log "Access policy ${pname} created for ${host}."
    fi
    policy_ids="$(printf '%s' "$policy_ids" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin) + ["'"${pid}"'"]))')"
  done
  handoff_routes="$(printf '%s' "$handoff_routes" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin) + [{"hostname": "'"${host}"'", "service": "'"$(service_for "${host}")"'", "dns_record_id": "'"${dns_id}"'", "access_app_id": "'"${app_id}"'", "policy_ids": json.loads(sys.argv[1])}]))' "$policy_ids")"
done

# --- 4. end-to-end verification (propagation retries, fail closed) ---
admin=''
ok_dash=0
for attempt in 1 2 3 4 5 6; do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --cookie-jar /dev/null --max-time 20 \
    -H "CF-Access-Client-Id: ${svc_id}" -H "CF-Access-Client-Secret: ${svc_secret}" \
    "https://${EDGE_HOSTNAME}/login" 2>/dev/null || true)"
  if [ "$code" = '200' ]; then ok_dash=1; break; fi
  log "dashboard attempt ${attempt}: HTTP ${code:-none} (waiting for propagation)..."
  sleep 20
done
svc_id=''; svc_secret=''; svc_token_id=''
[ "$ok_dash" -eq 1 ] || { echo "dashboard verification failed after 6 attempts (required exactly 200)." >&2; exit 1; }
log "edge verified: https://${EDGE_HOSTNAME}/login -> HTTP 200."
if [ -n "${SSH_HOSTNAME:-}" ]; then
  ok_ssh=0
  for attempt in 1 2 3 4 5 6; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --cookie-jar /dev/null --max-time 20 "https://${SSH_HOSTNAME}/" 2>/dev/null || true)"
    case "$code" in
      301|302|401|403) ok_ssh=1; break ;;
    esac
    log "ssh attempt ${attempt}: HTTP ${code:-none} (waiting for propagation)..."
    sleep 20
  done
  [ "$ok_ssh" -eq 1 ] || { echo "ssh route verification failed after 6 attempts (required a gated 301/302/401/403)." >&2; exit 1; }
  log "ssh route verified: https://${SSH_HOSTNAME}/ is live and policy-gated."
fi

if [ -n "$handoff_file" ]; then
  printf '{"tunnel_id":"%s","routes":%s}\n' "$tid" "$handoff_routes" >"$handoff_file"
  log "handoff written to ${handoff_file} (feed to scripts/emit-fresh-imports.sh)."
fi
log 'wire complete: ingress + DNS + Access + verification for all hostnames.'
