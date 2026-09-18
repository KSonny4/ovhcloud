#!/usr/bin/env bash
# Fail-closed live verification for the Nomad plane.
# Run from the operator machine (needs Bao + SSH + edge connectivity).
# Asserts, with a nonzero exit and a message on ANY failure:
#   1. edge UI serves (leader endpoint == 200 via Access service token),
#   2. single server + client alive (`nomad server members`, `node status`),
#   3. origin Nomad ports loopback-only (no 0.0.0.0:4646/4647/4648),
#   4. origin Docker ports closed at the DOCKER-USER boundary: DROP rules
#      present (v4+v6) AND the v4 DROP counter proves real external packets
#      are being dropped (background scanning provides the traffic, so no
#      external vantage is needed for this assertion),
#   5. jobs healthy (no failed/dead allocations on tracked jobs),
#   6. backup timer active.
# Prints statuses only — never secret values.
set -euo pipefail

NOMAD_HOST="${NOMAD_HOST:-nomad.pkubelka.cz}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/ovh_nomad_ed25519}"
HOST="${PROVISION_HOST:-}"
export BAO_ADDR="${BAO_ADDR:-https://secrets.pkubelka.cz}"
command -v bao >/dev/null 2>&1 || { echo 'bao required (fail closed).' >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo 'curl required (fail closed).' >&2; exit 2; }
command -v ssh >/dev/null 2>&1 || { echo 'ssh required (fail closed).' >&2; exit 2; }
[ -n "$HOST" ] || { echo 'PROVISION_HOST is required (no default origin IP).' >&2; exit 2; }

fail=0
check() { # $1=name $2=expected $3=actual
  if [ "$2" = "$3" ]; then echo "PASS $1 ($3)"; else echo "FAIL $1 (expected $2, got $3)"; fail=1; fi
}
ssh_run() { ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=20 "ubuntu@$HOST" "$1"; }

CID="$(bao kv get -field=client_id secret/projects/nomad/EDGE_ACCESS_SERVICE_TOKEN 2>/dev/null || true)"
CS="$(bao kv get -field=client_secret secret/projects/nomad/EDGE_ACCESS_SERVICE_TOKEN 2>/dev/null || true)"
[ -n "$CID" ] && [ -n "$CS" ] || { echo 'FAIL access service token unreadable from OpenBao'; exit 2; }

code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 -H "CF-Access-Client-Id: $CID" -H "CF-Access-Client-Secret: $CS" "https://${NOMAD_HOST}/v1/status/leader" || true)"
[ -n "$code" ] || code='curl-failed'
check 'edge leader endpoint' 200 "$code"
CID=''; CS=''

members="$(ssh_run 'export NOMAD_ADDR=http://127.0.0.1:4646; nomad server members 2>/dev/null | grep -c alive || true')"
check 'server members alive' 1 "$members"
nodes="$(ssh_run 'export NOMAD_ADDR=http://127.0.0.1:4646; nomad node status -short 2>/dev/null | grep -c ready || true')"
check 'client nodes ready' 1 "$nodes"

pub="$(ssh_run 'ss -lnt 2>/dev/null | grep -E "0.0.0.0:(4646|4647|4648)" || true')"
if [ -z "$pub" ]; then echo 'PASS nomad ports loopback-only'; else echo "FAIL public nomad listeners: $pub"; fail=1; fi

fw="$(ssh_run 'sudo bash /usr/local/sbin/ensure-docker-firewall.sh --check-only 2>&1' || true)"
case "$fw" in
  *'rules present'*) echo "PASS docker-firewall rules ($fw)" ;;
  *) echo "FAIL docker-firewall check: $fw"; fail=1 ;;
esac
# shellcheck disable=SC2016 # backslash-escapes expand in the REMOTE double-quoted shell, not locally: awk receives $3=="DROP".
drops="$(ssh_run 'sudo iptables -L DOCKER-USER -v -n 2>/dev/null | awk "\$3==\"DROP\" {print \$1}" | head -n1' || true)"
if [ -n "$drops" ] && [ "$drops" -gt 0 ] 2>/dev/null; then echo "PASS external DROP counter ($drops pkts dropped)"; else echo "FAIL no dropped external packets observed (counter=$drops)"; fail=1; fi

bad_allocs="$(ssh_run 'export NOMAD_ADDR=http://127.0.0.1:4646; nomad job status 2>/dev/null | grep -aiE "failed|dead" || true')"
if [ -z "$bad_allocs" ]; then echo 'PASS jobs healthy'; else echo "FAIL unhealthy jobs: $bad_allocs"; fail=1; fi
bad_containers="$(ssh_run "docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -aiE 'unhealthy|exited|dead|restarting|paused|created' || true")"
if [ -z "$bad_containers" ]; then echo 'PASS containers healthy'; else echo "FAIL unhealthy containers: $bad_containers"; fail=1; fi
timer="$(ssh_run 'systemctl is-active host-backup.timer 2>/dev/null' || true)"
check 'backup timer' active "$timer"

if [ "$fail" -eq 0 ]; then echo 'ALL LIVE CHECKS PASS'; else echo 'LIVE CHECKS FAILED'; exit 1; fi
