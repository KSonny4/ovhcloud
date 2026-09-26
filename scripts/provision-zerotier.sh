#!/usr/bin/env bash
# Join a host to the ZeroTier network that carries Nomad client traffic.
#
# Refs KSonny4/platform#27 (OVH join recorded 2026-09-26).
#
# Contract:
# - Runs as root ON the target host (OVH server first; the same script
#   serves a fresh host later). Repo-only lane: reviewed here, executed by
#   the owner — never run from an adoption task.
# - DRY-RUN BY DEFAULT: without --apply it prints what it would do and
#   changes nothing (exit 0). Pass --apply to install + join. --dry-run is
#   accepted explicitly as well.
# - The network ID comes from one place: config/clients/inventory.json
#   (`zerotier_network_id`; a network ID is not a secret — membership still
#   needs authorization in ZeroTier Central).
# - --apply installs zerotier-one via the official installer only if
#   zerotier-cli is absent (the OVH host was installed that way), then runs
#   `zerotier-cli join`, prints the node ID, and states that authorizing
#   the member in ZeroTier Central is a MANUAL owner step (no Central API
#   token exists in our tooling, so that step cannot be automated).
# - Verifies `zerotier-cli listnetworks` reports status OK (fail closed:
#   no OK, no success).
# - Idempotent: already joined + status OK = no-op with ALREADY_JOINED.
# - This script never touches Nomad, ufw or Docker, and never prints secret
#   values (there are none here: node IDs and network IDs are not secrets).
#
# Usage (on the host, as root):
#   sudo bash scripts/provision-zerotier.sh [--apply]
set -euo pipefail

apply=0
for arg in "$@"; do
  case "$arg" in
    --apply) apply=1 ;;
    --dry-run) apply=0 ;;
    -h|--help)
      echo 'usage: provision-zerotier.sh [--apply]'
      echo '  dry-run by default; --apply installs zerotier-one (if absent) and joins the network.'
      exit 0
      ;;
    *)
      echo "unknown argument: $arg (use --apply)" >&2
      exit 2
      ;;
  esac
done

log() { printf '%s\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INVENTORY="${INVENTORY:-${SCRIPT_DIR}/../config/clients/inventory.json}"
if [ ! -f "$INVENTORY" ]; then
  # Flattened shipping (inventory travels next to this script).
  INVENTORY="${SCRIPT_DIR}/inventory.json"
fi
if [ ! -f "$INVENTORY" ]; then
  echo "inventory not found (expected ../config/clients/inventory.json or ./inventory.json next to this script)." >&2
  exit 2
fi

inventory_get() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))'"$1"')' "$INVENTORY"
}

NETWORK_ID="$(inventory_get '["zerotier_network_id"]')"
case "$NETWORK_ID" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
    ;;
  *)
    echo "refusing to join: inventory zerotier_network_id '${NETWORK_ID}' is not a 16-hex-digit network ID." >&2
    exit 2
    ;;
esac
log "zerotier network: ${NETWORK_ID}"

# One line of `zerotier-cli listnetworks` for our network, or empty when
# not a member. (Output is `<code> listnetworks <nwid> <name> <mac>
# <status> <type> <dev> <ips…>`, so match the ID as a whole field.)
network_line() {
  zerotier-cli listnetworks 2>/dev/null | grep -E "(^|[[:space:]])${NETWORK_ID}([[:space:]]|$)" || true
}

if [ "$apply" -eq 0 ]; then
  log "DRY-RUN: install zerotier-one via the official installer (only if zerotier-cli is absent) + zerotier-cli join ${NETWORK_ID}"
  log 'DRY-RUN: print the node ID (zerotier-cli info) — authorizing the member in ZeroTier Central is a MANUAL owner step (no Central API token in tooling)'
  log 'DRY-RUN: verify zerotier-cli listnetworks reports status OK (fail closed)'
  exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
  echo 'must run as root (installs zerotier-one + joins the network).' >&2
  exit 2
fi

if ! command -v zerotier-cli >/dev/null 2>&1; then
  log 'zerotier-cli absent: installing zerotier-one via the official installer.'
  curl -fsSL https://install.zerotier.com/ | bash
else
  log 'zerotier-one already installed.'
fi

if [ -n "$(network_line)" ]; then
  log "ALREADY_JOINED: already a member of ${NETWORK_ID}."
else
  zerotier-cli join "$NETWORK_ID"
fi

NODE_ID="$(zerotier-cli info | awk '{print $3}')"
log "node ID: ${NODE_ID}"
log 'NEXT OWNER STEP (manual): authorize this member in ZeroTier Central — no Central API token exists in our tooling, so this cannot be automated.'

# Verify membership status OK (fail closed: authorize in Central, re-run).
status=''
for _ in $(seq 1 30); do
  if network_line | grep -qE '(^|[[:space:]])OK([[:space:]]|$)'; then status='OK'; break; fi
  sleep 2
done
if [ "$status" != "OK" ]; then
  echo "zerotier network ${NETWORK_ID} has no OK status after 60s (fail closed: authorize the member in Central, then re-run)." >&2
  exit 1
fi
log "NETWORK_OK: member of ${NETWORK_ID}, status OK."
