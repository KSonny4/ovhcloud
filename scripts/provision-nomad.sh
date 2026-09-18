#!/usr/bin/env bash
# Install and configure Nomad (single server + client) on the target host.
#
# Contract:
# - Runs as root ON the target host (fresh provision or rebuild).
# - Installs the pinned Nomad release (checksum-verified zip, never an
#   unreviewed pipe), writes the single-node config (loopback bind,
#   bootstrap_expect = 1, ACL enabled, Docker driver), installs the
#   systemd unit, enables + starts the agent, waits for leadership.
# - ACL bootstrap: the runner supplies NOMAD_GOSSIP_KEY (generated +
#   escrowed runner-side when absent). This script ACL-bootstraps once and
#   prints the bootstrap SecretID/AccessorID on a single delimited line for
#   the runner to escrow operator-side (memory-only, never logged by the
#   runner); when the cluster is already bootstrapped it prints
#   BOOTSTRAP_EXISTS and changes nothing.
# - Idempotent: same version installed + agent healthy + bootstrapped =
#   no-op with INSTALLED_SAME / AGENT_HEALTHY / BOOTSTRAP_EXISTS.
# - This script never prints secret values except the single bootstrap
#   escrow line consumed over the runner's SSH channel.
#
# Usage (on the host, as root):
#   sudo NOMAD_VERSION=2.0.6 NOMAD_GOSSIP_KEY=<32-char-base64> bash scripts/provision-nomad.sh [--dry-run]
set -euo pipefail

dry_run=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    -h|--help) echo 'usage: provision-nomad.sh [--dry-run]'; exit 0 ;;
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

NOMAD_VERSION="${NOMAD_VERSION:-2.0.6}"
NOMAD_ADDR="${NOMAD_ADDR:-http://127.0.0.1:4646}"
export NOMAD_ADDR
# Immutable service-identity guard: this script runs as root on the target
# itself, so the self-check (not a target label) stops a mistaken run on
# the preserved box. Safe in dry-run (no network without OVH creds).
GUARD_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/preserved-guard.sh
source "${GUARD_SCRIPT_DIR}/lib/preserved-guard.sh"
refuse_preserved_self || exit 2
log "nomad version: ${NOMAD_VERSION}"

if [ "$dry_run" -eq 1 ]; then
  log 'DRY-RUN: install nomad binary (checksum-verified) + write /etc/nomad.d/nomad.hcl (single server+client, loopback, ACL on, docker driver) + systemd unit'
  log 'DRY-RUN: enable --now nomad, wait for leadership, ACL-bootstrap once (or BOOTSTRAP_EXISTS), emit escrow line for runner-side escrow'
  exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
  echo 'must run as root (installs binary + config + unit).' >&2
  exit 2
fi
if [ -z "${NOMAD_GOSSIP_KEY:-}" ]; then
  echo 'NOMAD_GOSSIP_KEY is required (runner generates + escrows when absent).' >&2
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
    && curl -fsSLO "https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_linux_amd64.zip" \
    && curl -fsSLO "https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_SHA256SUMS" \
    && grep "nomad_${NOMAD_VERSION}_linux_amd64.zip" "nomad_${NOMAD_VERSION}_SHA256SUMS" | sha256sum -c - \
    && unzip -o "nomad_${NOMAD_VERSION}_linux_amd64.zip" -d /usr/local/bin )
  chmod +x /usr/local/bin/nomad
  trap - EXIT
  rm -rf "$workdir"
  log "installed nomad ${NOMAD_VERSION} (checksum verified)."
fi

mkdir -p /opt/nomad /etc/nomad.d /opt/nomad-volumes/registry
cat >/etc/nomad.d/nomad.hcl <<HCL_EOF
datacenter = "ovh-vps"
data_dir   = "/opt/nomad"
bind_addr  = "127.0.0.1"

# Single node: loopback advertise is correct — all consumers (tunnel,
# local CLI) use loopback. Required on Nomad 2.x with a loopback bind.
advertise {
  http = "127.0.0.1:4646"
  rpc  = "127.0.0.1:4647"
  serf = "127.0.0.1:4648"
}

server {
  enabled          = true
  bootstrap_expect = 1
}

client {
  enabled = true
  servers = ["127.0.0.1:4647"]

  host_network "loopback" {
    interface = "lo"
  }

  # Backs the registry job's volume "data" (type = host). The htpasswd
  # file content is rendered from OpenBao escrow at deploy time into
  # /opt/nomad-volumes/registry-auth/ (see docs/09-docker-registry.md).
  host_volume "registry-data" {
    path      = "/opt/nomad-volumes/registry"
    read_only = false
  }
}

acl {
  enabled = true
}

plugin "docker" {
  config {
    allow_privileged = false
    volumes {
      enabled = true
    }
  }
}
HCL_EOF
chmod 600 /etc/nomad.d/nomad.hcl
log 'wrote /etc/nomad.d/nomad.hcl (single server+client, loopback, ACL on).'

# Gossip key ships in a separate protected file (0600, never in Git) so
# the main config stays committable. Written BEFORE the first start: the
# server must boot encrypted from the beginning.
cat >/etc/nomad.d/gossip.hcl <<GOSSIP_EOF
server {
  encrypt = "${NOMAD_GOSSIP_KEY}"
}
GOSSIP_EOF
chmod 600 /etc/nomad.d/gossip.hcl
log 'wrote /etc/nomad.d/gossip.hcl (0600).'

cat >/etc/systemd/system/nomad.service <<'UNIT_EOF'
[Unit]
Description=Nomad single-node agent
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

# Wait for leadership (fail closed: no leader, no bootstrap).
leader=''
for _ in $(seq 1 30); do
  leader="$(curl -fsS --max-time 5 "${NOMAD_ADDR}/v1/status/leader" 2>/dev/null || true)"
  if [ -n "$leader" ] && [ "$leader" != '""' ]; then break; fi
  sleep 2
done
if [ -z "$leader" ] || [ "$leader" = '""' ]; then
  echo 'no Nomad leader after 60s (fail closed).' >&2
  exit 1
fi
log "AGENT_HEALTHY: leader ${leader}"

# ACL bootstrap (once per cluster lifetime).
bootstrap_out="$(nomad acl bootstrap -json 2>&1 || true)"
case "$bootstrap_out" in
  *'"SecretID"'*)
    secret="$(printf '%s' "$bootstrap_out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["SecretID"])')"
    accessor="$(printf '%s' "$bootstrap_out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessorID"])')"
    printf 'NOMAD_BOOTSTRAP_ESCROW secret=%s accessor=%s\n' "$secret" "$accessor"
    ;;
  *'already bootstrapped'*)
    log 'BOOTSTRAP_EXISTS: cluster already bootstrapped; nothing changed.'
    ;;
  *)
    echo "acl bootstrap failed: ${bootstrap_out}" >&2
    exit 1
    ;;
esac
