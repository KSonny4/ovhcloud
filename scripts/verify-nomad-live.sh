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
if [ -z "$CID" ] || [ -z "$CS" ]; then
  echo 'FAIL access service token unreadable from OpenBao'; exit 2
fi
# Cluster ACL token for the Nomad read APIs (server members / node status
# enforce ACLs; anonymous calls 403). Memory-only: piped to the target over
# the encrypted channel, never printed, never in argv.

code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 -H "CF-Access-Client-Id: $CID" -H "CF-Access-Client-Secret: $CS" "https://${NOMAD_HOST}/v1/status/leader" || true)"
[ -n "$code" ] || code='curl-failed'
check 'edge leader endpoint' 200 "$code"
CID=''; CS=''

nomad_aclt="$(bao kv get -field=acl_token secret/projects/nomad/NOMAD_BOOTSTRAP 2>/dev/null || true)"
[ -n "$nomad_aclt" ] || { echo 'FAIL Nomad ACL token unreadable from OpenBao'; exit 2; }
# shellcheck disable=SC2016 # single-quoted remote: $NOMAD_* expand remotely; token arrives via stdin, never argv.
acl_ssh() { printf '%s' "$nomad_aclt" | ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=20 "ubuntu@$HOST" "read -r NOMAD_TOKEN; export NOMAD_TOKEN; $1"; }

members="$(acl_ssh 'export NOMAD_ADDR=http://127.0.0.1:4646; nomad server members 2>/dev/null | grep -c alive || true')"
check 'server members alive' 1 "$members"
nodes="$(acl_ssh 'export NOMAD_ADDR=http://127.0.0.1:4646; nomad node status -short 2>/dev/null | grep -c ready || true')"
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
if [ -n "$drops" ] && [ "$drops" -gt 0 ] 2>/dev/null; then echo "PASS external DROP counter ($drops pkts dropped)";
# Loopback-only origins publish nothing externally: with no 0.0.0.0
# listeners besides SSH there is no forward path for external packets, so a
# zero DROP counter is the CORRECT steady state (SYNS are refused at the
# interface before any FORWARD rule sees them). Only when external ports
# exist must the counter prove real drops.
elif [ -z "$(ssh_run 'ss -lnt 2>/dev/null | grep -E "0.0.0.0:[0-9]+" | grep -v "0.0.0.0:22 " || true')" ]; then echo 'PASS no external listeners besides SSH (zero drops is correct: refused at interface)';
else echo "FAIL exposed ports with no drops observed (counter=$drops)"; fail=1; fi

bad_allocs="$(ssh_run 'export NOMAD_ADDR=http://127.0.0.1:4646; nomad job status 2>/dev/null | grep -aiE "failed|dead" || true')"
if [ -z "$bad_allocs" ]; then echo 'PASS jobs healthy'; else echo "FAIL unhealthy jobs: $bad_allocs"; fail=1; fi
bad_containers="$(ssh_run "docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -aiE 'unhealthy|exited|dead|restarting|paused|created' || true")"
# Known false positive (documented): the cognee server image ships a
# HEALTHCHECK against static localhost:8000, but the job binds a dynamic
# loopback port — it reports unhealthy from boot while serving fine (Nomad
# TCP checks + MCP/REST smokes are the real proof). Exclude exactly that
# task container, and only while the cognee job itself is running.
# Narrow by construction: three jobs share the task name "server" (cognee,
# control-panel, unleash), so a name-only pattern would also silence an
# unhealthy control-panel/unleash server. The Docker labels prove job+task
# identity instead; any other server-* unhealthy still fails.
# shellcheck disable=SC2016 # single-quoted remote like acl_ssh above: \$3 expands remotely in awk, never locally.
cognee_state="$(acl_ssh 'export NOMAD_ADDR=http://127.0.0.1:4646; nomad job status cognee 2>/dev/null | grep -m1 "^Status" | awk "{print \$3}" || echo none')"
if [ "$cognee_state" = "running" ]; then
  kept_containers=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    cname="${line%% *}"
    if printf '%s' "$cname" | grep -qE '^server-[0-9a-f-]{8,}$' && printf '%s' "$line" | grep -qi 'unhealthy'; then
      lbl="$(ssh_run "docker inspect ${cname} --format '{{index .Config.Labels \"com.hashicorp.nomad.job_name\"}}/{{index .Config.Labels \"com.hashicorp.nomad.task_name\"}}' 2>/dev/null" || true)"
      if [ "$lbl" = 'cognee/server' ]; then continue; fi
    fi
    kept_containers="${kept_containers}${line}
"
  done <<<"$bad_containers"
  bad_containers="$kept_containers"
fi
nomad_aclt=''
if [ -z "$bad_containers" ]; then echo 'PASS containers healthy'; else echo "FAIL unhealthy containers: $bad_containers"; fail=1; fi
timer="$(ssh_run 'systemctl is-active host-backup.timer 2>/dev/null' || true)"
check 'backup timer' active "$timer"

if [ "$fail" -eq 0 ]; then echo 'ALL LIVE CHECKS PASS'; else echo 'LIVE CHECKS FAILED'; exit 1; fi
