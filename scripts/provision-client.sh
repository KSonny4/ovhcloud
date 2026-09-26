#!/usr/bin/env bash
# Install and configure Nomad as a *client* (pool `home`) on a home host.
#
# Refs KSonny4/platform#27 (Slice P, repo part).
#
# Contract:
# - Runs as root ON the target host (Pi or Fujitsu). Repo-only lane: the
#   join itself (Slice P step 3 [YES]) is NOT part of this change, so this
#   script is reviewed here but never executed against a host in this lane.
# - DRY-RUN BY DEFAULT: without --apply it prints what it would do and
#   changes nothing (exit 0). Pass --apply to install.
# - Nomad version comes from one place: config/clients/inventory.json
#   (`nomad_version`; must match the scripts/provision-nomad.sh default —
#   tests/test_nomad_clients.py enforces it). NOMAD_VERSION in the
#   environment overrides only as an operator escape hatch.
# - Host facts (ZeroTier IP, arch) come from the same inventory file.
# - Installs the pinned Nomad release for the host arch
#   (checksum-verified zip, never an unreviewed pipe), installs the
#   matching committed client config (config/clients/<host>.hcl) as
#   /etc/nomad.d/client.hcl plus the provision-time gossip file, installs
#   the systemd unit, enables + starts the agent.
# - Idempotent: same version installed + agent healthy = no-op with
#   INSTALLED_SAME / AGENT_HEALTHY.
# - This script never prints secret values. NOMAD_GOSSIP_KEY (the same
#   cluster gossip key as the server) is required for --apply and ships in
#   /etc/nomad.d/gossip.hcl (0600, never in Git), like the server.
#
# Usage (on the host, as root):
#   sudo bash scripts/provision-client.sh --host pi [--apply]
#   sudo bash scripts/provision-client.sh --host fujitsu [--apply]
set -euo pipefail

apply=0
host=''
prev=''
for arg in "$@"; do
  if [ "$prev" = "--host" ]; then host="$arg"; prev=''; continue; fi
  case "$arg" in
    --apply) apply=1 ;;
    --host) prev='--host' ;;
    --host=*) host="${arg#--host=}" ;;
    -h|--help)
      echo 'usage: provision-client.sh --host pi|fujitsu [--apply]'
      echo '  dry-run by default; --apply installs the Nomad client.'
      exit 0
      ;;
    pi|fujitsu)
      echo "positional host '$arg' is not accepted; use --host $arg" >&2
      exit 2
      ;;
    *)
      echo "unknown argument: $arg (use --host pi|fujitsu)" >&2
      exit 2
      ;;
  esac
done
if [ "$prev" = "--host" ]; then
  echo '--host needs a value: --host pi|fujitsu' >&2
  exit 2
fi
if [ "$host" != "pi" ] && [ "$host" != "fujitsu" ]; then
  echo 'a host is required: --host pi|fujitsu' >&2
  exit 2
fi

log() { printf '%s\n' "$*"; }
run() {
  if [ "$apply" -eq 0 ]; then
    log "DRY-RUN: $*"
  else
    "$@"
  fi
}

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

NOMAD_VERSION="${NOMAD_VERSION:-$(inventory_get '["nomad_version"]')}"
HOST_ARCH="$(inventory_get '["hosts"]["'"$host"'"]["arch"]')"
HOST_IP="$(inventory_get '["hosts"]["'"$host"'"]["zerotier_ip"]')"
log "nomad version: ${NOMAD_VERSION} (host ${host}, arch ${HOST_ARCH}, zerotier ${HOST_IP})"

case "$HOST_ARCH" in
  amd64|arm64) ;;
  *)
    echo "unsupported arch '${HOST_ARCH}' for host '${host}' (expected amd64|arm64)." >&2
    exit 2
    ;;
esac

NOMAD_ZIP="nomad_${NOMAD_VERSION}_linux_${HOST_ARCH}.zip"
NOMAD_URL="https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/${NOMAD_ZIP}"

# The client agent config is the committed file config/clients/<host>.hcl
# — install it, never generate a copy here, so the host always runs exactly
# what Git holds. The file travels next to this script: ../config/clients/
# in a checkout, or flattened to ./<host>.hcl when shipped.
CLIENT_SRC=''
for candidate in "${SCRIPT_DIR}/../config/clients/${host}.hcl" "${SCRIPT_DIR}/${host}.hcl"; do
  if [ -f "$candidate" ]; then CLIENT_SRC="$candidate"; break; fi
done
if [ -z "$CLIENT_SRC" ]; then
  echo "committed client config not found (expected ../config/clients/${host}.hcl or ./${host}.hcl next to this script)." >&2
  exit 2
fi

if [ "$apply" -eq 0 ]; then
  log "DRY-RUN: install nomad ${NOMAD_VERSION} (${NOMAD_ZIP}, checksum-verified) + install committed ${CLIENT_SRC} -> /etc/nomad.d/client.hcl (client-only, pool home, zerotier bind, docker without bind mounts) + systemd unit"
  log 'DRY-RUN: enable --now nomad, wait for client heartbeat (fail closed)'
  exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
  echo 'must run as root (installs binary + config + unit).' >&2
  exit 2
fi
if [ -z "${NOMAD_GOSSIP_KEY:-}" ]; then
  echo 'NOMAD_GOSSIP_KEY is required (same cluster gossip key as the server).' >&2
  exit 2
fi
command -v docker >/dev/null 2>&1 || { echo 'docker not found on this host; the Nomad client needs it.' >&2; exit 2; }

if nomad version 2>/dev/null | grep -q "v${NOMAD_VERSION}"; then
  log 'INSTALLED_SAME: pinned Nomad release already present.'
else
  command -v unzip >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq unzip; }
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' EXIT
  ( cd "$workdir" \
    && curl -fsSLO "${NOMAD_URL}" \
    && curl -fsSLO "https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_SHA256SUMS" \
    && grep "${NOMAD_ZIP}" "nomad_${NOMAD_VERSION}_SHA256SUMS" | sha256sum -c - \
    && unzip -o "${NOMAD_ZIP}" -d /usr/local/bin )
  chmod +x /usr/local/bin/nomad
  trap - EXIT
  rm -rf "$workdir"
  log "installed nomad ${NOMAD_VERSION} (${HOST_ARCH}, checksum verified)."
fi

mkdir -p /opt/nomad /etc/nomad.d
run install -m 600 "$CLIENT_SRC" /etc/nomad.d/client.hcl
log "installed /etc/nomad.d/client.hcl from ${CLIENT_SRC} (client-only, pool home)."

# Gossip key ships in a separate protected file (0600, never in Git) so
# the main config stays committable. Written BEFORE the first start: the
# client must join encrypted from the beginning.
cat >/etc/nomad.d/gossip.hcl <<GOSSIP_EOF
server {
  encrypt = "${NOMAD_GOSSIP_KEY}"
}
GOSSIP_EOF
chmod 600 /etc/nomad.d/gossip.hcl
log 'wrote /etc/nomad.d/gossip.hcl (0600).'

cat >/etc/systemd/system/nomad.service <<'UNIT_EOF'
[Unit]
Description=Nomad client agent (pool home)
After=network-online.target docker.service
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/nomad agent -config=/etc/nomad.d
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT_EOF
run systemctl daemon-reload
run systemctl enable --now nomad

# Wait for the client heartbeat (fail closed: no heartbeat, no success).
heartbeat=''
for _ in $(seq 1 30); do
  heartbeat="$(nomad node status -self 2>/dev/null || true)"
  if [ -n "$heartbeat" ]; then break; fi
  sleep 2
done
if [ -z "$heartbeat" ]; then
  echo 'no client heartbeat after 60s (fail closed).' >&2
  exit 1
fi
log 'AGENT_HEALTHY: client heartbeat observed.'
