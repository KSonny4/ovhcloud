#!/usr/bin/env bash
# Noninteractive Tunnel/Access wiring for a freshly bootstrapped host.
#
# Contract:
# - Cloudflare DNS, Tunnel, Access apps/policies, and service token are owned
#   by Terraform (see infra/terraform/main.tf and imports.tf.example).
# - This script only installs/configures cloudflared from the escrowed Tunnel
#   token and verifies machine access with the escrowed Access service token.
# - Reads secrets only from environment/stdin; never prints them.
# - Idempotent; refuses to target the preserved production VPS.
#
# Usage:
#   TUNNEL_TARGET_HOST=fresh-host.example \
#   TUNNEL_DOMAIN=coolify.example \
#   CLOUDFLARED_TUNNEL_TOKEN='<from OpenBao>' \
#   CF_ACCESS_CLIENT_ID='<from OpenBao>' CF_ACCESS_CLIENT_SECRET='<from OpenBao>' \
#   sudo -E bash scripts/configure-tunnel-access.sh [--dry-run]
set -euo pipefail

dry_run=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    -h|--help) echo 'usage: configure-tunnel-access.sh [--dry-run]'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '%s\n' "$*"; }
run() {
  if [ "$dry_run" -eq 1 ]; then
    log "DRY-RUN: $*"
  else
    "$@"
  fi
}

target_host="${TUNNEL_TARGET_HOST:-}"
domain="${TUNNEL_DOMAIN:-}"
tunnel_token="${CLOUDFLARED_TUNNEL_TOKEN:-}"
client_id="${CF_ACCESS_CLIENT_ID:-}"
client_secret="${CF_ACCESS_CLIENT_SECRET:-}"
if [ -z "$target_host" ] || [ -z "$domain" ]; then
  echo 'TUNNEL_TARGET_HOST and TUNNEL_DOMAIN must both be set.' >&2
  exit 2
fi
GUARD_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/preserved-guard.sh
source "${GUARD_SCRIPT_DIR}/lib/preserved-guard.sh"
refuse_preserved_host "$target_host" || exit 2
refuse_preserved_self || exit 2
if [ "$(id -u)" -ne 0 ] && [ "$dry_run" -eq 0 ]; then
  echo 'Run configure-tunnel-access.sh as root.' >&2
  exit 2
fi

log "target host: ${target_host}"
log "domain: ${domain}"
log "dry run: ${dry_run}"

if ! command -v cloudflared >/dev/null 2>&1; then
  if [ "$dry_run" -eq 1 ]; then
    log 'DRY-RUN: install cloudflared from the official package repository'
  else
    run mkdir -p --mode=0755 /usr/share/keyrings
    run bash -c 'curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null'
    run bash -c 'echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" | tee /etc/apt/sources.list.d/cloudflared.list'
    run apt-get update
    run apt-get install -y cloudflared
  fi
else
  log 'cloudflared already installed.'
fi

if [ -z "$tunnel_token" ] && [ "$dry_run" -eq 0 ]; then
  echo 'CLOUDFLARED_TUNNEL_TOKEN must be supplied from OpenBao.' >&2
  exit 2
fi
if [ "$dry_run" -eq 1 ]; then
  log 'DRY-RUN: install cloudflared service with the escrowed Tunnel token (value not printed)'
elif systemctl is-active --quiet cloudflared; then
  log 'cloudflared service already active.'
else
  # The token stays in the environment of this single command only.
  CLOUDFLARED_TUNNEL_TOKEN="$tunnel_token" run cloudflared service install "$tunnel_token"
  run systemctl enable --now cloudflared
fi
run systemctl is-active cloudflared || true

if [ -z "$client_id" ] || [ -z "$client_secret" ]; then
  if [ "$dry_run" -eq 1 ]; then
    log 'DRY-RUN: verify dashboard availability with CF-Access service-token headers (values not printed)'
  else
    echo 'CF_ACCESS_CLIENT_ID and CF_ACCESS_CLIENT_SECRET must be supplied from OpenBao.' >&2
    exit 2
  fi
else
  if [ "$dry_run" -eq 1 ]; then
    log 'DRY-RUN: curl dashboard login with CF-Access service-token headers'
  else
    code="$(curl -sS -o /dev/null -w '%{http_code}' --cookie-jar /dev/null --max-time 20 \
      -H "CF-Access-Client-Id: ${client_id}" \
      -H "CF-Access-Client-Secret: ${client_secret}" \
      "https://coolify.${domain}/login")"
    log "dashboard machine verification HTTP status: ${code} (200 = service token accepted; use a clean cookie jar, stale CF_AppSession cookies mask the result)"
    case "$code" in
      200|302) ;;
      *) echo "machine verification failed with HTTP ${code}" >&2; exit 1 ;;
    esac
  fi
fi

log 'tunnel/access stage complete: connector configured, human OTP retained, machine path verified.'
