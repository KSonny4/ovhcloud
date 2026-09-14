#!/usr/bin/env bash
# Fail-closed live verification for the Coolify dashboard fixes.
# Run from the operator machine (needs Bao + SSH + edge connectivity).
# Asserts, with a nonzero exit and a message on ANY failure:
#   1. edge dashboard serves (/login == 200 via Access service token),
#   2. edge realtime websocket upgrades (== 101),
#   3. running proxy image == EXPECTED_PROXY_IMAGE (default traefik:v3.7)
#      and matches the DB-configured tag (no drift),
#   4. origin Docker ports closed at the DOCKER-USER boundary: DROP rules
#      present (v4+v6) AND the v4 DROP counter proves real external packets
#      are being dropped (background scanning provides the traffic, so no
#      external vantage is needed for this assertion),
#   5. workloads healthy (no unhealthy/exited Coolify/fabric containers),
#   6. backup timer active.
# Prints statuses only — never secret values.
set -euo pipefail

EXPECTED_PROXY_IMAGE="${EXPECTED_PROXY_IMAGE:-traefik:v3.7}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/ovh_coolify_ed25519}"
HOST="${PROVISION_HOST:-57.129.155.203}"
export BAO_ADDR="${BAO_ADDR:-https://secrets.pkubelka.cz}"
command -v bao >/dev/null 2>&1 || { echo 'bao required (fail closed).' >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo 'curl required (fail closed).' >&2; exit 2; }
command -v ssh >/dev/null 2>&1 || { echo 'ssh required (fail closed).' >&2; exit 2; }

fail=0
check() { # $1=name $2=expected $3=actual
  if [ "$2" = "$3" ]; then echo "PASS $1 ($3)"; else echo "FAIL $1 (expected $2, got $3)"; fail=1; fi
}
ssh_run() { ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=20 "ubuntu@$HOST" "$1"; }

CID="$(bao kv get -field=client_id secret/projects/ovhcloud/COOLIFY_ACCESS_SERVICE_TOKEN 2>/dev/null || true)"
CS="$(bao kv get -field=client_secret secret/projects/ovhcloud/COOLIFY_ACCESS_SERVICE_TOKEN 2>/dev/null || true)"
[ -n "$CID" ] && [ -n "$CS" ] || { echo 'FAIL access service token unreadable from OpenBao'; exit 2; }

code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 -H "CF-Access-Client-Id: $CID" -H "CF-Access-Client-Secret: $CS" 'https://coolify.pkubelka.cz/login' || true)"
[ -n "$code" ] || code='curl-failed'
check 'edge dashboard /login' 200 "$code"

AID="$(ssh_run 'docker exec coolify-realtime printenv SOKETI_DEFAULT_APP_ID 2>/dev/null' || true)"
[ -n "$AID" ] || { echo 'FAIL realtime app id unreadable (container down?)'; fail=1; }
if [ -n "$AID" ]; then
  code="$(curl -s -o /dev/null -w '%{http_code}' --http1.1 --max-time 25 -H "CF-Access-Client-Id: $CID" -H "CF-Access-Client-Secret: $CS" -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "https://coolify.pkubelka.cz/app/$AID?protocol=7&client=js&version=8&flash=false" || true)"
  [ -n "$code" ] || code='curl-failed'
  check 'edge realtime WS upgrade' 101 "$code"
fi
CID=''; CS=''; AID=''

running="$(ssh_run "docker inspect coolify-proxy --format '{{.Config.Image}}' 2>/dev/null" || true)"
check 'running proxy image' "$EXPECTED_PROXY_IMAGE" "$running"
configured="$(ssh_run "sudo grep -aE \"^[[:space:]]*image:\" /data/coolify/proxy/docker-compose.yml 2>/dev/null | head -n1 | grep -oE 'traefik:v[0-9.]+'" || true)"
check 'file proxy tag matches running' "$running" "$configured"

fw="$(ssh_run 'sudo bash /usr/local/sbin/ensure-docker-firewall.sh --check-only 2>&1' || true)"
case "$fw" in
  *'rules present'*) echo "PASS docker-firewall rules ($fw)" ;;
  *) echo "FAIL docker-firewall check: $fw"; fail=1 ;;
esac
drops="$(ssh_run 'sudo iptables -L DOCKER-USER -v -n 2>/dev/null | awk "\$3==\"DROP\" {print \$1}" | head -n1' || true)"
if [ -n "$drops" ] && [ "$drops" -gt 0 ] 2>/dev/null; then echo "PASS external DROP counter ($drops pkts dropped)"; else echo "FAIL no dropped external packets observed (counter=$drops)"; fail=1; fi

bad="$(ssh_run "docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -aiE 'unhealthy|exited|dead|restarting|paused|created' || true")"
if [ -z "$bad" ]; then echo 'PASS workloads healthy'; else echo "FAIL unhealthy containers: $bad"; fail=1; fi
for need in coolify-proxy coolify-realtime; do ssh_run "docker ps --format '{{.Names}}' 2>/dev/null" | grep -aq "^${need}$" && echo "PASS $need present" || { echo "FAIL $need missing"; fail=1; }; done
timer="$(ssh_run 'systemctl is-active coolify-backup.timer 2>/dev/null' || true)"
check 'backup timer' active "$timer"

[ "$fail" -eq 0 ] && echo 'ALL LIVE CHECKS PASS' || { echo 'LIVE CHECKS FAILED'; exit 1; }
