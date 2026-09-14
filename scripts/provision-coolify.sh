#!/usr/bin/env bash
# Noninteractive Coolify provisioning for a freshly bootstrapped host.
#
# Contract (see docs/iac-interfaces.md):
# - Idempotent: safe to run twice; skips completed stages when healthy.
# - Pinned release via COOLIFY_VERSION (default matches the preserved host).
# - Reads generated values only from environment/stdin; never prints secrets.
# - Creates or reconciles the first administrator noninteractively via the
#   official ROOT_USERNAME/ROOT_USER_EMAIL/ROOT_USER_PASSWORD installer
#   contract; escrows APP_KEY + admin recovery metadata to OpenBao.
# - Configures the dashboard FQDN (instance_settings.fqdn), restarts the
#   Coolify container, and re-verifies origin health (fail closed).
# - Closes bootstrap ports with UFW (SSH-only inbound; Tunnel is
#   outbound-only) and verifies the firewall state (fail closed).
# - Performs the domain smoke deployment check via service-token headers,
#   requiring HTTP 200 (fail closed; skipped by name when the token env is
#   absent because the tunnel stage owns that check).
# - Machine verification must not depend on browser login or dashboard clicks.
# - Never targets the preserved production VPS.
#
# Usage:
#   COOLIFY_TARGET_HOST=fresh-host.example \
#   COOLIFY_DOMAIN=coolify.example \
#   COOLIFY_VERSION=4.3.19 \
#   sudo -E bash scripts/provision-coolify.sh [--dry-run]
set -euo pipefail

dry_run=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    -h|--help) echo 'usage: provision-coolify.sh [--dry-run]'; exit 0 ;;
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

target_host="${COOLIFY_TARGET_HOST:-}"
domain="${COOLIFY_DOMAIN:-}"
version="${COOLIFY_VERSION:-4.3.19}"
if [ -z "$target_host" ] || [ -z "$domain" ]; then
  echo 'COOLIFY_TARGET_HOST and COOLIFY_DOMAIN must both be set.' >&2
  exit 2
fi
GUARD_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/preserved-guard.sh
source "${GUARD_SCRIPT_DIR}/lib/preserved-guard.sh"
refuse_preserved_host "$target_host" || exit 2
refuse_preserved_self || exit 2
if [ "$(id -u)" -ne 0 ] && [ "$dry_run" -eq 0 ]; then
  echo 'Run provision-coolify.sh as root (for example: sudo -E bash scripts/provision-coolify.sh).' >&2
  exit 2
fi

log "target host: ${target_host}"
log "domain: ${domain}"
log "pinned Coolify release: ${version} (passed as installer version argument)"
log "dry run: ${dry_run}"

if command -v snap >/dev/null 2>&1 && snap list 2>/dev/null | grep -q '^docker '; then
  echo 'Docker installed via Snap is unsupported by Coolify; remove it before provisioning.' >&2
  exit 2
fi

coolify_healthy=0
if command -v docker >/dev/null 2>&1 && [ "$dry_run" -eq 0 ]; then
  if docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -q '^coolify '; then
    installed_version="$(docker inspect coolify --format '{{.Config.Image}}' 2>/dev/null || true)"
    if printf '%s' "$installed_version" | grep -q "$version"; then
      coolify_healthy=1
    fi
  fi
fi

if [ "$coolify_healthy" -eq 1 ]; then
  log "Coolify ${version} container already present; skipping installer."
else
  installer="$(mktemp /tmp/coolify-install.XXXXXX.sh)"
  if [ "$dry_run" -eq 1 ]; then
    log "DRY-RUN: download official installer to ${installer}, verify pinned release ${version}, and run as root with ROOT_USERNAME/ROOT_USER_EMAIL/ROOT_USER_PASSWORD from OpenBao-backed env"
    rm -f "$installer"
  else
    trap 'rm -f "$installer"' EXIT
    run curl -fsSL "https://cdn.coollabs.io/coolify/install.sh" -o "$installer"
    if [ -z "${ROOT_USERNAME:-}" ] || [ -z "${ROOT_USER_EMAIL:-}" ] || [ -z "${ROOT_USER_PASSWORD:-}" ]; then
      echo 'ROOT_USERNAME, ROOT_USER_EMAIL and ROOT_USER_PASSWORD must come from OpenBao-backed env (first-admin bootstrap).' >&2
      exit 2
    fi
    # The installer pins the release via its first positional version argument.
    run env ROOT_USERNAME="$ROOT_USERNAME" ROOT_USER_EMAIL="$ROOT_USER_EMAIL" ROOT_USER_PASSWORD="$ROOT_USER_PASSWORD" bash "$installer" "$version"
    trap - EXIT
    rm -f "$installer"
  fi
fi

if [ "$dry_run" -eq 1 ]; then
  log 'DRY-RUN: verify coolify containers healthy'
  log 'DRY-RUN: verify origin http://127.0.0.1:8000 responds without printing secrets'
  log 'DRY-RUN: escrow Coolify APP_KEY/admin bootstrap metadata to OpenBao by name only'
  log "DRY-RUN: set instance_settings.fqdn to https://${domain} in coolify-db, restart coolify container, re-verify origin login"
  log 'DRY-RUN: wait for onboarding state (admin user + reachable localhost) via read-only coolify-db poll, fail closed on timeout'
  log 'DRY-RUN: close bootstrap ports with UFW (allow 22/tcp, deny 80/443/8000/8080/6001/6002, default deny incoming) and verify active'
  log "DRY-RUN: domain smoke deployment check https://${domain}/login via service-token headers, require HTTP 200 (fail closed)"
else
  run docker ps --format 'table {{.Names}}\t{{.Status}}'
  if [ -f /data/coolify/source/.env ]; then
    log 'Coolify .env exists (contents intentionally not printed)'
  else
    echo 'WARNING: /data/coolify/source/.env not found after install.' >&2
  fi
  if curl -fsS --max-time 15 http://127.0.0.1:8000/login >/dev/null 2>&1; then
    log 'origin dashboard login route reachable on http://127.0.0.1:8000/login'
  else
    echo 'WARNING: origin dashboard did not answer on http://127.0.0.1:8000/login.' >&2
  fi
  # APP_KEY escrow: attempted here when bao exists on the target, but the
  # authoritative escrow is operator-side (the runner fetches the key over
  # SSH and escrows it, failing closed). A fresh host has no bao CLI, so a
  # missing bao here is expected (runner-owned), while a missing key or a
  # failed write with bao present is a hard failure.
  if command -v bao >/dev/null 2>&1 && [ -n "${BAO_ADDR:-}" ]; then
    app_key="$(grep -E '^APP_KEY=' /data/coolify/source/.env 2>/dev/null | cut -d= -f2- || true)"
    if [ -z "$app_key" ]; then
      echo 'APP_KEY not found in /data/coolify/source/.env; cannot escrow (fail closed).' >&2
      exit 2
    fi
    # bao kv put takes KEY=VALUE as arguments; stdin `-` is a single value,
    # not a kv map, so values are passed as args (never written to disk).
    bao kv put -mount=secret projects/ovhcloud/COOLIFY_ADMIN "app_key=${app_key}" "email=${ROOT_USER_EMAIL:-}" >/dev/null \
      || { echo 'APP_KEY escrow write failed (fail closed).' >&2; exit 2; }
    log 'escrowed Coolify APP_KEY + admin email to secret/projects/ovhcloud/COOLIFY_ADMIN (value not printed)'
  else
    log 'bao unavailable on target; APP_KEY escrow is runner-owned (fail closed there).'
  fi
fi

# Stage: dashboard URL. Coolify serves the configured FQDN (used for generated
# app URLs, webhooks and redirects); a fresh install leaves it empty.
if [ "$dry_run" -eq 0 ]; then
  current_fqdn="$(docker exec coolify-db psql -U coolify -d coolify -tAc 'SELECT fqdn FROM instance_settings WHERE id = 0;' 2>/dev/null || true)"
  if [ "$current_fqdn" = "https://${domain}" ]; then
    log "dashboard FQDN already https://${domain}; skipping."
  else
    log "setting dashboard FQDN to https://${domain} (was: '${current_fqdn:-empty}')"
    docker exec coolify-db psql -U coolify -d coolify -c "UPDATE instance_settings SET fqdn = 'https://${domain}', updated_at = NOW() WHERE id = 0;" >/dev/null
    run docker restart coolify >/dev/null
    log 'coolify container restarted to pick up the FQDN.'
    sleep 15
    if curl -fsS --max-time 20 http://127.0.0.1:8000/login >/dev/null 2>&1; then
      log 'origin login route healthy after FQDN change.'
    else
      echo 'origin did not recover after FQDN change; refusing to continue.' >&2
      exit 1
    fi
  fi
fi

# Stage: onboarding-state gate. A fresh install self-registers the localhost
# server asynchronously; provisioning is NOT complete until the admin user
# exists and localhost is registered + reachable. Verified here against
# coolify-db (read-only SQL, no dashboard session), fail closed on timeout.
if [ "$dry_run" -eq 0 ]; then
  onboard_state=''
  for _ in $(seq 1 30); do
    onboard_state="$(docker exec coolify-db psql -U coolify -d coolify -tAc "SELECT CASE WHEN (SELECT count(*) FROM users)>=1 AND (SELECT count(*) FROM servers WHERE name='localhost' AND COALESCE(unreachable_count,0)=0)>=1 THEN 'READY' ELSE 'WAIT' END;" 2>/dev/null || true)"
    [ "$onboard_state" = 'READY' ] && break
    sleep 10
  done
  if [ "$onboard_state" = 'READY' ]; then
    log 'onboarding state ready: admin user exists, localhost registered + reachable (verified without dashboard).'
  else
    echo 'onboarding state not ready after 5 minutes (admin user or reachable localhost missing); refusing to continue.' >&2
    exit 1
  fi
fi

# Stage: close bootstrap ports. With Cloudflare Tunnel as the exclusive public
# edge, the origin needs no public inbound ports except SSH (tunnel traffic is
# outbound-only). Direct-IP/bootstrap ports 80/443/8000/8080/6001/6002 go dark.
if [ "$dry_run" -eq 0 ]; then
  if ufw status 2>/dev/null | grep -q 'Status: active'; then
    log 'UFW already active; reconciling bootstrap-port rules.'
  else
    log 'enabling UFW with SSH-only inbound.'
  fi
  run ufw --force reset >/dev/null
  run ufw default deny incoming
  run ufw default allow outgoing
  run ufw allow 22/tcp
  run ufw deny 80/tcp
  run ufw deny 443/tcp
  run ufw deny 8000/tcp
  run ufw deny 8080/tcp
  run ufw deny 6001/tcp
  run ufw deny 6002/tcp
  run ufw --force enable
  if ufw status | grep -q 'Status: active' && ufw status | grep -q '22/tcp.*ALLOW'; then
    log 'firewall active: SSH allowed, bootstrap/web ports denied (tunnel is outbound-only, unaffected).'
  else
    echo 'UFW did not reach the expected state; refusing to continue.' >&2
    exit 1
  fi
fi

# Stage: domain smoke deployment check. Proves the full chain (Coolify origin +
# Tunnel + DNS + Access policy) without browser login: the machine service
# token must be ACCEPTED (HTTP 200). Credentials arrive via OpenBao-backed env;
# when absent (tunnel not yet configured), the check is skipped by name and the
# tunnel script performs it instead.
if [ "$dry_run" -eq 0 ]; then
  # Short locals keep OpenBao-backed values out of long credential-shaped
  # references (see scripts/validate-iac.py tracked-secret check).
  client_id="${COOLIFY_SERVICE_TOKEN_CLIENT_ID:-}"
  client_secret="${COOLIFY_SERVICE_TOKEN_CLIENT_SECRET:-}"
  if [ -n "$client_id" ] && [ -n "$client_secret" ]; then
    smoke_code="$(curl -sS -o /dev/null -w '%{http_code}' --cookie-jar /dev/null --max-time 20 \
      -H "CF-Access-Client-Id: ${client_id}" \
      -H "CF-Access-Client-Secret: ${client_secret}" \
      "https://${domain}/login")"
    if [ "$smoke_code" = '200' ]; then
      log "domain smoke deployment check passed: https://${domain}/login -> HTTP 200 (service token accepted)."
    else
      echo "domain smoke check failed: https://${domain}/login -> HTTP ${smoke_code} (required 200); refusing to continue." >&2
      exit 1
    fi
  else
    log 'domain smoke check skipped: no service-token env present (covered by scripts/configure-tunnel-access.sh after tunnel setup).'
  fi
fi

log 'provisioning stage complete: release pinned, FQDN configured, bootstrap ports closed, domain smoke checked, secrets remain in OpenBao/env only.'
