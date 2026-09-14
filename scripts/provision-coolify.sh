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
if [ "$target_host" = 'vps-1525c977.vps.ovh.net' ] || [ "$target_host" = '57.129.155.203' ]; then
  echo 'Refusing to re-provision the preserved production VPS with the fresh-host script.' >&2
  exit 2
fi
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
  if command -v bao >/dev/null 2>&1 && [ -n "${BAO_ADDR:-}" ]; then
    app_key="$(grep -E '^APP_KEY=' /data/coolify/source/.env 2>/dev/null | cut -d= -f2- || true)"
    if [ -z "$app_key" ]; then
      echo 'WARNING: APP_KEY not found in /data/coolify/source/.env; escrow skipped.' >&2
    else
      # bao kv put takes KEY=VALUE as arguments; stdin `-` is a single value,
      # not a kv map, so values are passed as args (never written to disk).
      bao kv put -mount=secret projects/ovhcloud/COOLIFY_ADMIN "app_key=${app_key}" "email=${ROOT_USER_EMAIL:-}" >/dev/null
      log 'escrowed Coolify APP_KEY + admin email to secret/projects/ovhcloud/COOLIFY_ADMIN (value not printed)'
    fi
  else
    echo 'WARNING: bao/BAO_ADDR unavailable; APP_KEY escrow must be completed by the runner.' >&2
  fi
fi

log 'provisioning stage complete: release pinned, containers checked, secrets remain in OpenBao/env only.'
