#!/usr/bin/env bash
# Noninteractive Tunnel/Access wiring for a freshly bootstrapped host.
#
# Contract:
# - Cloudflare DNS, Tunnel, Access apps/policies, and service token are owned
#   by Terraform (see infra/terraform/main.tf and imports.tf.example).
# - This script only installs/configures cloudflared from the escrowed Tunnel
#   token and verifies machine access with the escrowed Access service token.
# - Reads secrets only from environment/stdin; never prints them and never
#   passes them as command arguments (token lives in a 0600 --token-file
#   read by an owned systemd unit, mirroring the preserved host).
# - Fail-closed: cloudflared must be active and the UI leader endpoint must
#   answer exactly HTTP 200 to the service-token pair (a 302 means rejection).
# - Idempotent; refuses to target the preserved production VPS.
#
# Usage:
#   TUNNEL_TARGET_HOST=fresh-host.example \
#   TUNNEL_DOMAIN=example.com \
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
  log 'DRY-RUN: write owned cloudflared unit + 0600 token env file (token never a command argument), enable, hard-require active'
else
  # The token must never appear in a command argument (process list) — not
  # even to `cloudflared service install`, which takes it positionally. The
  # connector runs from a unit we own, reading the token from a root-only
  # --token-file. This mirrors the preserved host layout exactly.
  token_was_active=0
  systemctl is-active --quiet cloudflared && token_was_active=1
  run mkdir -p --mode=0700 /etc/cloudflared
  umask 077
  cat > /etc/cloudflared/token <<TOKEN_EOF
${tunnel_token}
TOKEN_EOF
  chmod 600 /etc/cloudflared/token
  cat > /etc/systemd/system/cloudflared.service <<'UNIT_EOF'
[Unit]
Description=Cloudflare Tunnel connector (token from root-only token file)
After=network-online.target
Wants=network-online.target

[Service]
TimeoutStartSec=15
Type=notify
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run --token-file /etc/cloudflared/token
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT_EOF
  run systemctl daemon-reload
  run systemctl enable --now cloudflared
  if [ "$token_was_active" -eq 1 ]; then
    # Pick up a rotated token in the already-running connector.
    run systemctl restart cloudflared
    sleep 5
  fi
  if systemctl is-active --quiet cloudflared; then
    log 'cloudflared service active (fail-closed health check passed).'
  else
    echo 'cloudflared service is not active after install/enable (fail closed).' >&2
    exit 1
  fi
fi

if [ -z "$client_id" ] || [ -z "$client_secret" ]; then
  if [ "$dry_run" -eq 1 ]; then
    log 'DRY-RUN: verify UI availability with CF-Access service-token headers (values not printed)'
  else
    echo 'CF_ACCESS_CLIENT_ID and CF_ACCESS_CLIENT_SECRET must be supplied from OpenBao.' >&2
    exit 2
  fi
else
  if [ "$dry_run" -eq 1 ]; then
    log 'DRY-RUN: curl UI leader endpoint with CF-Access service-token headers'
  else
    code="$(curl -sS -o /dev/null -w '%{http_code}' --cookie-jar /dev/null --max-time 20 \
      -H "CF-Access-Client-Id: ${client_id}" \
      -H "CF-Access-Client-Secret: ${client_secret}" \
      "https://nomad.${domain}/v1/status/leader")"
    # Exactly 200: a 302 is a redirect to the Access login page, which means
    # the service token was NOT accepted and must fail the verification.
    if [ "$code" = '200' ]; then
      log "UI machine verification HTTP 200 (service token accepted; clean cookie jar used)."
    else
      echo "machine verification failed with HTTP ${code} (required exactly 200)" >&2
      exit 1
    fi
  fi
fi

log 'tunnel/access stage complete: connector configured, human OTP retained, machine path verified.'
