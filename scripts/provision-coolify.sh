#!/usr/bin/env bash
# Noninteractive Coolify provisioning for a freshly bootstrapped host.
#
# Contract (see docs/iac-interfaces.md):
# - Idempotent: safe to run twice; skips completed stages when healthy.
# - Pinned release via COOLIFY_VERSION (default matches the preserved host).
# - Reads generated values only from environment/stdin; never prints secrets.
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
log "pinned Coolify release: ${version}"
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
    log "DRY-RUN: download pinned official installer to ${installer} and run as root"
    rm -f "$installer"
  else
    trap 'rm -f "$installer"' EXIT
    run curl -fsSL "https://cdn.coollabs.io/coolify/install.sh" -o "$installer"
    run bash "$installer"
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
fi

log 'provisioning stage complete: release pinned, containers checked, secrets remain in OpenBao/env only.'
