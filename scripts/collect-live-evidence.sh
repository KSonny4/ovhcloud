#!/usr/bin/env bash
# Collect independently re-runnable live evidence (operator side, read-only).
#
# Queries live provider/host state and writes redacted machine-readable
# proofs to docs/live-proofs.json: resource IDs (identifiers, never secrets),
# timestamps, statuses, and secret-free command output. Re-running this
# script reproduces the file; anyone can verify each claim with the
# documented read-only commands. Secret values are never printed, stored,
# or embedded (IDs and counts only).
#
# Usage:
#   BAO_ADDR=https://secrets.pkubelka.cz bash scripts/collect-live-evidence.sh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
log() { printf '%s\n' "$*" >&2; }
out="$repo_root/evidence-archive/live-proofs.json"

[ -n "${BAO_ADDR:-}" ] || { echo 'BAO_ADDR must be set.' >&2; exit 2; }
command -v bao >/dev/null 2>&1 || { echo 'bao CLI is required.' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo 'jq is required.' >&2; exit 2; }

loader_out="$(BAO_ADDR="$BAO_ADDR" bash "$repo_root/scripts/tf-env-from-openbao.sh")" || { echo 'OpenBao loader failed.' >&2; exit 2; }
eval "$loader_out"

acct='5eb3ea3a84b37564cfd8739f32ffb559'
zone='0fcca39cc6516b8e23971bd717c0e9ca'
# shellcheck disable=SC2154 # TF_VAR_* arrive via the eval'd OpenBao loader above
cf() { curl -sS --max-time 30 -H "Authorization: Bearer $TF_VAR_cloudflare_api_token" "https://api.cloudflare.com/client/v4$1"; }

uts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tunnels="$(cf "/accounts/${acct}/cfd_tunnel" | jq -c '[.result[] | {id, name, status}]')"
dns="$(cf "/zones/${zone}/dns_records?name=nomad.pkubelka.cz" | jq -c '[.result[] | {id, name, type, content, proxied}]')"
dns_ssh="$(cf "/zones/${zone}/dns_records?name=ssh.pkubelka.cz" | jq -c '[.result[] | {id, name, type, content, proxied}]')"
apps="$(cf "/accounts/${acct}/access/apps" | jq -c '[.result[] | {id, name, domain}]')"
r2_objects="$(AWS_DEFAULT_REGION=auto aws --endpoint-url "$R2_ENDPOINT" s3 ls "s3://${R2_BUCKET}/" --recursive 2>/dev/null | awk '{print $4}' | jq -R . | jq -cs '{count: length, sample_keys: .[:5]}')"
ev_ssh_key="${EVIDENCE_SSH_KEY:-$HOME/.ssh/ovh_nomad_ed25519}"
ev_ssh_host="${EVIDENCE_SSH_HOST:-ubuntu@57.129.155.203}"
nomad_status="$(ssh -i "$ev_ssh_key" -o BatchMode=yes -o ConnectTimeout=20 "$ev_ssh_host" 'export NOMAD_ADDR=http://127.0.0.1:4646; nomad server members 2>/dev/null | grep -c alive; curl -sS -o /dev/null -w "%{http_code}" --max-time 10 http://127.0.0.1:4646/v1/status/leader 2>/dev/null; docker ps --format "{{.Names}} {{.Status}}" 2>/dev/null | grep -cE "Up|healthy" || true')"
timer_status="$(ssh -i "$ev_ssh_key" -o BatchMode=yes -o ConnectTimeout=20 "$ev_ssh_host" 'systemctl is-active host-backup.timer cloudflared nomad 2>&1 | tr "\n" " " || true')"
# Firewall posture (tunnel-only: 80/443 denied), container image pins, and
# the reseed stamps (latest snapshot + app manifest keys prove
# tonight's-plane state without narrative).
ufw_status="$(ssh -i "$ev_ssh_key" -o BatchMode=yes -o ConnectTimeout=20 "$ev_ssh_host" 'sudo ufw status numbered 2>/dev/null | grep -E "^\[|Status" || true')"
docker_images="$(ssh -i "$ev_ssh_key" -o BatchMode=yes -o ConnectTimeout=20 "$ev_ssh_host" 'docker ps --format "{{.Names}}={{.Image}}" 2>/dev/null | sort || true')"
latest_dump="$(AWS_DEFAULT_REGION=auto aws --endpoint-url "$R2_ENDPOINT" s3 ls "s3://${R2_BUCKET}/" 2>/dev/null | awk '{print $4}' | grep '^nomad-snapshot-' | sort | tail -n1 || true)"
latest_manifest="$(AWS_DEFAULT_REGION=auto aws --endpoint-url "$R2_ENDPOINT" s3 ls "s3://${R2_BUCKET}/app-manifests/" 2>/dev/null | awk '{print $4}' | sort | tail -n1 || true)"
# Snapshot round-trip integrity: GET the latest snapshot and verify it
# downloads intact (proves the R2 GET path + backup usability,
# machine-checked).
dump_integrity='missing'
if [ -n "$latest_dump" ]; then
  tmp_dump="$(mktemp /tmp/evidence-dump.XXXXXX.gz)"
  if AWS_DEFAULT_REGION=auto aws --endpoint-url "$R2_ENDPOINT" s3api get-object --bucket "$R2_BUCKET" --key "${latest_dump}" "$tmp_dump" >/dev/null 2>&1 && gzip -t "$tmp_dump" 2>/dev/null; then
    dump_integrity="gzip-ok ${latest_dump}"
  else
    dump_integrity="FAILED ${latest_dump}"
  fi
  rm -f "$tmp_dump"
fi

# JSON travels via argv + json.loads (never interpolated into source:
# JSON true/false/null are not valid Python literals).
python3 - "$uts" "$tunnels" "$dns" "$dns_ssh" "$apps" "$r2_objects" "$nomad_status" "$timer_status" "$ufw_status" "$docker_images" "$latest_dump" "$latest_manifest" "$dump_integrity" >"$out" <<'PYEOF'
import json, sys
_, uts, tunnels, dns, dns_ssh, apps, r2, ncont, units, ufw, images, dump, manifest, integrity = sys.argv
print(json.dumps({
  "collected_utc": uts,
  "tunnels": json.loads(tunnels or 'null'),
  "dns_nomad": json.loads(dns or 'null'),
  "dns_ssh": json.loads(dns_ssh or 'null'),
  "access_apps": json.loads(apps or 'null'),
  "r2_bucket_objects": json.loads(r2 or 'null'),
  "vps_containers_running": ncont,
  "host_units": units,
  "ufw_status": ufw,
  "docker_images": images,
  "latest_snapshot": dump,
  "latest_app_manifest": manifest,
  "dump_roundtrip_integrity": integrity,
}, indent=2))
PYEOF
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY TF_VAR_cloudflare_api_token TF_VAR_service_token_id CLOUDFLARE_API_TOKEN OVH_ENDPOINT OVH_APPLICATION_KEY OVH_APPLICATION_SECRET OVH_CONSUMER_KEY R2_ENDPOINT R2_BUCKET 2>/dev/null || true
log "live evidence collected at $uts -> evidence-archive/live-proofs.json (IDs and counts only, no secrets)."
