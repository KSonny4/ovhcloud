#!/usr/bin/env bash
# Per-stage live proofs (redacted, machine-checkable).
#
# The aggregate live-proofs.json snapshot cannot show WHICH stage proved
# what. This collector executes one check per deployment stage against the
# live system and records {stage, utc, ok, detail} with IDs/codes/counts
# only (never tokens, keys, or values) to evidence-archive/live-proofs-stages.json:
# preserved-safety, bootstrap, nomad, tunnel-access, r2-backup, restore,
# rollback, api-roundtrip. Restore/rollback run in probe mode (production
# untouched); the DNS round-trip creates and DELETES a disposable record.
#
# Usage: [BAO_ADDR=...] [EVIDENCE_SSH_KEY=...] bash scripts/collect-stage-proofs.sh [--stamp STAMP]
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
out="$repo_root/evidence-archive/live-proofs-stages.json"
stamp=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --stamp) stamp="$2"; shift 2 ;;
    --stamp=*) stamp="${1#--stamp=}"; shift ;;
    -h|--help) echo 'usage: collect-stage-proofs.sh [--stamp STAMP]'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
command -v bao >/dev/null 2>&1 || { echo 'bao CLI is required.' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo 'jq is required.' >&2; exit 2; }
export BAO_ADDR="${BAO_ADDR:-https://secrets.pkubelka.cz}"
ev_ssh_key="${EVIDENCE_SSH_KEY:-$HOME/.ssh/ovh_nomad_ed25519}"
ev_ssh_host="${EVIDENCE_SSH_HOST:-ubuntu@57.129.155.203}"
ssh="ssh -i $ev_ssh_key -o BatchMode=yes -o ConnectTimeout=20 $ev_ssh_host"
uts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
results='[]'
record() { results="$(printf '%s' "$results" | python3 -c 'import json,sys; r=json.load(sys.stdin); r.append({"stage":sys.argv[1],"utc":sys.argv[2],"ok":sys.argv[3]=="1","detail":sys.argv[4]}); print(json.dumps(r))' "$1" "$2" "$3" "$4")"; }

# Stage 1: preserved-VPS safety (local execution, no SSH): the guard must
# refuse the current origin's service name and IPv4.
# shellcheck source=scripts/lib/preserved-guard.sh
source "$repo_root/scripts/lib/preserved-guard.sh"
t0="$(uts)"
safe_ok=1; safe_detail=''
if refuse_preserved_host 'vps-c85da816.vps.ovh.ca' >/dev/null 2>&1; then safe_ok=0; safe_detail='service-name refusal MISSING'; else safe_detail='service-name refused'; fi
if refuse_preserved_host '148.113.245.89' >/dev/null 2>&1; then safe_ok=0; safe_detail="${safe_detail}; ipv4 refusal MISSING"; else safe_detail="${safe_detail}; ipv4 refused"; fi
record preserved-safety "$t0" "$safe_ok" "$safe_detail"

# Stage 2: bootstrap (Docker + firewall posture + hello-world execution).
t0="$(uts)"
docker_v="$($ssh 'docker --version 2>/dev/null' || true)"
ufw_line="$($ssh 'sudo ufw status 2>/dev/null | grep -E "Status|80/tcp" | tr "\n" ";"' || true)"
hello="$($ssh 'docker run --rm hello-world 2>&1 | grep -c "Hello from Docker" || true')"
if [ -n "$docker_v" ] && printf '%s' "$ufw_line" | grep -q 'active' && printf '%s' "$ufw_line" | grep -q 'DENY' && [ "$hello" -ge 1 ]; then
  record bootstrap "$t0" 1 "${docker_v}; ufw ${ufw_line}; hello-world runs"
else
  record bootstrap "$t0" 0 "docker='${docker_v}' ufw='${ufw_line}' hello='${hello}'"
fi

# Stage 3: nomad (agent alive + origin leader endpoint).
t0="$(uts)"
healthy="$($ssh 'docker ps --format "{{.Names}} {{.Status}}" 2>/dev/null | grep -cE "Up|healthy" || true')"
origin_code="$($ssh 'curl -s -o /dev/null -w "%{http_code}" --max-time 15 http://127.0.0.1:4646/v1/status/leader 2>/dev/null || true')"
members="$($ssh 'export NOMAD_ADDR=http://127.0.0.1:4646; nomad server members 2>/dev/null | grep -c alive || true')"
if [ "${members:-0}" -ge 1 ] && [ "$origin_code" = '200' ]; then
  record nomad "$t0" 1 "server_members_alive=${members}; origin_leader=${origin_code}; healthy_containers=${healthy}"
else
  record nomad "$t0" 0 "server_members_alive=${members}; origin_leader=${origin_code}; healthy_containers=${healthy}"
fi

# OpenBao-sourced API inputs (memory-only; unset at the end with the rest).
admin="$(bao kv get -field=ADMIN_CLOUDFLARE secret/projects/nomad/ADMIN_CLOUDFLARE 2>/dev/null || true)"
svc_id="$(bao kv get -field=client_id secret/projects/nomad/EDGE_ACCESS_SERVICE_TOKEN 2>/dev/null || true)"
svc_secret="$(bao kv get -field=client_secret secret/projects/nomad/EDGE_ACCESS_SERVICE_TOKEN 2>/dev/null || true)"
zone='0fcca39cc6516b8e23971bd717c0e9ca'
if [ -z "$admin" ] || [ -z "$svc_id" ] || [ -z "$svc_secret" ]; then echo 'OpenBao API escrow incomplete.' >&2; exit 2; fi

# Stage 4: tunnel-access (machine 200 on UI leader, gated code on ssh route).
t0="$(uts)"
ui_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -H "CF-Access-Client-Id: ${svc_id}" -H "CF-Access-Client-Secret: ${svc_secret}" 'https://nomad.pkubelka.cz/v1/status/leader' 2>/dev/null || true)"
ssh_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 'https://ssh.pkubelka.cz/' 2>/dev/null || true)"
if [ "$ui_code" = '200' ] && { [ "$ssh_code" = '301' ] || [ "$ssh_code" = '302' ] || [ "$ssh_code" = '401' ] || [ "$ssh_code" = '403' ]; }; then
  record tunnel-access "$t0" 1 "ui_leader=${ui_code}; ssh_route_gated=${ssh_code}"
else
  record tunnel-access "$t0" 0 "ui_leader=${ui_code}; ssh_route=${ssh_code}"
fi

# R2 handles (memory-only env, same pattern as the collectors).
r2_ak="$(bao kv get -field=access_key_id secret/projects/nomad/BACKUP_R2 2>/dev/null || true)"
r2_sk="$(bao kv get -field=secret_access_key secret/projects/nomad/BACKUP_R2 2>/dev/null || true)"
r2_ep="$(bao kv get -field=endpoint secret/projects/nomad/BACKUP_R2 2>/dev/null || true)"
r2_bucket="$(bao kv get -field=bucket secret/projects/nomad/BACKUP_R2 2>/dev/null || true)"
export AWS_ACCESS_KEY_ID="$r2_ak" AWS_SECRET_ACCESS_KEY="$r2_sk" AWS_DEFAULT_REGION=auto
if [ -z "$stamp" ]; then
  stamp="$(aws --endpoint-url "$r2_ep" s3 ls "s3://${r2_bucket}/app-manifests/" 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]{8}T[0-9]{6}Z' | sort | tail -n1 || true)"
fi
[ -n "$stamp" ] || { echo 'no app manifest stamp found.' >&2; exit 2; }

# Stage 5: r2-backup (reseed stamps exist for the current plane).
t0="$(uts)"
snap_key="$(aws --endpoint-url "$r2_ep" s3 ls "s3://${r2_bucket}/" 2>/dev/null | awk '{print $4}' | grep '^nomad-snapshot-' | sort | tail -n1 || true)"
manifest_key="${stamp}.json"
if [ -n "$snap_key" ] && aws --endpoint-url "$r2_ep" s3api head-object --bucket "$r2_bucket" --key "app-manifests/${manifest_key}" >/dev/null 2>&1; then
  record r2-backup "$t0" 1 "snapshot=${snap_key}; app_manifest=${manifest_key}"
else
  record r2-backup "$t0" 0 "snapshot=${snap_key}; app_manifest=${manifest_key}"
fi

# Stages 6-7: restore + rollback probes (repo code staged to /tmp, cleaned).
scp -i "$ev_ssh_key" -o BatchMode=yes -o ConnectTimeout=15 "$repo_root/scripts/rollback-nomad-snapshot.sh" "$repo_root/scripts/rollback-app-workloads.sh" "${ev_ssh_host}:/tmp/" >/dev/null
t0="$(uts)"
restore_out="$($ssh 'sudo /root/host-backup/fetch-r2-env.sh -- bash /tmp/rollback-nomad-snapshot.sh 2>&1' | grep -aE 'RESTORE_OK|FAILED' | head -n2 || true)"
if printf '%s' "$restore_out" | grep -q RESTORE_OK; then record restore "$t0" 1 "$restore_out"; else record restore "$t0" 0 "${restore_out:-no restore output}"; fi
t0="$(uts)"
rollback_log="$($ssh "sudo /root/host-backup/fetch-r2-env.sh -- bash /tmp/rollback-app-workloads.sh --stamp $stamp 2>&1" || true)"
rollback_ok="$(printf '%s' "$rollback_log" | grep -cE 'RESTORE_OK' || true)"
rollback_fail="$(printf '%s' "$rollback_log" | grep -cE 'FAILED' || true)"
if [ "$rollback_ok" -ge 1 ] && [ "$rollback_fail" -eq 0 ]; then record rollback "$t0" 1 "restore_ok_lines=${rollback_ok}; stamp=${stamp}"; else record rollback "$t0" 0 "restore_ok_lines=${rollback_ok}; failed_lines=${rollback_fail}; stamp=${stamp}"; fi
$ssh 'rm -f /tmp/rollback-nomad-snapshot.sh /tmp/rollback-app-workloads.sh' >/dev/null 2>&1 || true

# Stage 8: disposable API round-trip (fresh-path write): create, verify, delete.
t0="$(uts)"
rt_name='_stageproof.pkubelka.cz'
created=''
cleanup_rt() { if [ -n "$created" ]; then curl -s -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer ${admin}" "https://api.cloudflare.com/client/v4/zones/${zone}/dns_records/${created}" >/dev/null 2>&1 || true; fi }
trap cleanup_rt EXIT
mk_resp="$(curl -s --max-time 30 -X POST -H "Authorization: Bearer ${admin}" -H 'Content-Type: application/json' -d '{"type":"TXT","name":"'"$rt_name"'","content":"stage-proof-disposable","ttl":60}' "https://api.cloudflare.com/client/v4/zones/${zone}/dns_records" 2>/dev/null || true)"
if printf '%s' "$mk_resp" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("success") is True else 1)' 2>/dev/null; then
  created="$(printf '%s' "$mk_resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["id"])')"
  got="$(curl -s --max-time 30 -H "Authorization: Bearer ${admin}" "https://api.cloudflare.com/client/v4/zones/${zone}/dns_records?type=TXT&name=${rt_name}" 2>/dev/null | python3 -c 'import json,sys; r=json.load(sys.stdin).get("result",[]); print(r[0].get("content","") if r else "")' 2>/dev/null || true)"
  del_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X DELETE -H "Authorization: Bearer ${admin}" "https://api.cloudflare.com/client/v4/zones/${zone}/dns_records/${created}" 2>/dev/null || true)"
  created=''
  if [ "$got" = 'stage-proof-disposable' ] && [ "$del_code" = '200' ]; then
    record api-roundtrip "$t0" 1 "txt create+verify+delete ok (record removed)"
  else
    record api-roundtrip "$t0" 0 "verify='${got}' delete='${del_code}'"
  fi
else
  record api-roundtrip "$t0" 0 'record creation failed'
fi
trap - EXIT

python3 -c 'import json,sys; print(json.dumps({"collected_utc": sys.argv[1], "stages": json.loads(sys.argv[2])}, indent=2))' "$(uts)" "$results" >"$out"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY TF_VAR_cloudflare_api_token 2>/dev/null || true
fail_n="$(printf '%s' "$results" | python3 -c 'import json,sys; print(sum(1 for s in json.load(sys.stdin) if not s["ok"]))')"
echo "stage proofs collected -> evidence-archive/live-proofs-stages.json (failures: ${fail_n})."
[ "$fail_n" -eq 0 ]
