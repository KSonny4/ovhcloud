#!/usr/bin/env bash
# Noninteractive fresh-VPS bootstrap for the OVHcloud/Coolify redesign.
#
# Design contract (see docs/iac-interfaces.md):
# - Runs unattended after an authorized operator supplies provider authorization.
# - Reads secrets only from the environment or stdin; never commits or prints them.
# - Idempotent: safe to run twice on the same host.
# - Never reinstalls, reboots without BOOTSTRAP_ALLOW_REBOOT=1, or touches a
#   preserved production host unless BOOTSTRAP_TARGET_HOST is explicit.
# - Version-aware: refuses unsupported Ubuntu releases before changing anything.
# - Installs Docker Engine from the official apt repository when absent,
#   then verifies it (engine version + hello-world), because the official
#   Coolify installer assumes a working Docker.
#
# Usage:
#   BOOTSTRAP_TARGET_HOST=fresh-host.example \
#   BOOTSTRAP_SSH_PUBLIC_KEY="$(cat key.pub)" \
#   sudo -E bash scripts/bootstrap-vps.sh [--dry-run]
#
# Optional:
#   BOOTSTRAP_ALLOW_REBOOT=1        allow reboot when /var/run/reboot-required exists
#   BOOTSTRAP_SUPPORTED_RELEASES="24.04 26.04"
#   BOOTSTRAP_SWAP_SIZE=2G
set -euo pipefail

dry_run=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    -h|--help)
      echo 'usage: bootstrap-vps.sh [--dry-run]'
      exit 0
      ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
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

target_host="${BOOTSTRAP_TARGET_HOST:-}"
if [ -z "$target_host" ]; then
  echo 'BOOTSTRAP_TARGET_HOST must name the intended fresh host.' >&2
  exit 2
fi
# Immutable service-identity guard (resolves the target; a literal comparison
# is bypassed by any alternate route to the same machine) plus a self-check
# so a lying TARGET variable cannot provision the preserved box itself.
GUARD_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/preserved-guard.sh
source "${GUARD_SCRIPT_DIR}/lib/preserved-guard.sh"
refuse_preserved_host "$target_host" || exit 2
refuse_preserved_self || exit 2

supported_releases="${BOOTSTRAP_SUPPORTED_RELEASES:-24.04 26.04}"
swap_size="${BOOTSTRAP_SWAP_SIZE:-2G}"
ssh_public_key="${BOOTSTRAP_SSH_PUBLIC_KEY:-}"

release='unknown'
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  release="$(. /etc/os-release && printf '%s' "${VERSION_ID:-unknown}")"
fi
supported=0
for candidate in $supported_releases; do
  if [ "$release" = "$candidate" ]; then
    supported=1
    break
  fi
done
if [ "$dry_run" -eq 1 ] && [ ! -r /etc/os-release ] && [ "$(uname -s)" = 'Darwin' ]; then
  release='dry-run'
  supported=1
fi
if [ "$supported" -ne 1 ]; then
  echo "Unsupported Ubuntu release ${release}; supported releases: ${supported_releases}." >&2
  exit 2
fi

if [ "$(id -u)" -ne 0 ] && [ "$dry_run" -eq 0 ]; then
  echo 'Run bootstrap-vps.sh as root (for example: sudo -E bash scripts/bootstrap-vps.sh).' >&2
  exit 2
fi

log "target host: ${target_host}"
log "ubuntu release: ${release}"
log "dry run: ${dry_run}"

run apt-get update
run env DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y
run apt-get install -y --no-install-recommends \
  ca-certificates curl git jq vim htop tmux \
  openssh-server unattended-upgrades python3

run hostnamectl set-hostname ovh-coolify-fresh || true
run timedatectl set-timezone UTC || true

for user_home in /home/ubuntu /root; do
  user_name="$(basename "$user_home")"
  if [ -d "$user_home" ] && [ -n "$ssh_public_key" ]; then
    run install -d -m 700 "${user_home}/.ssh"
    if [ "$dry_run" -eq 1 ]; then
      log "DRY-RUN: install trusted SSH public key for ${user_name}"
    else
      tmp_key="$(mktemp)"
      printf '%s\n' "$ssh_public_key" >"$tmp_key"
      touch "${user_home}/.ssh/authorized_keys"
      chmod 600 "${user_home}/.ssh/authorized_keys"
      cat "$tmp_key" >>"${user_home}/.ssh/authorized_keys"
      sort -u "${user_home}/.ssh/authorized_keys" -o "${user_home}/.ssh/authorized_keys"
      if [ "$user_name" = 'ubuntu' ]; then
        chown -R ubuntu:ubuntu /home/ubuntu/.ssh || true
      fi
      rm -f "$tmp_key"
    fi
  fi
done

run install -m 644 /dev/null /etc/ssh/sshd_config.d/99-ovh-hardening.conf
if [ "$dry_run" -eq 1 ]; then
  log 'DRY-RUN: write key-only OpenSSH hardening drop-in'
else
  cat >/etc/ssh/sshd_config.d/99-ovh-hardening.conf <<'EOF'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin prohibit-password
X11Forwarding no
MaxAuthTries 3
EOF
fi
run sshd -t
run systemctl restart ssh

# Managed automation channel: the exact environment variables the
# provisioning/rollback automation ships via stdin-piped env (never argv)
# must survive sudo (this image has NOPASSWD without SETENV, so -E is
# ignored). Additive env_keep only; validated before use.
# Single source of truth: scripts/lib/sudoers-automation-env (shipped to
# remote_dir/lib by the runner; also installed as step 0 before any sudo -E
# stage, so this block is convergence for hosts provisioned by other paths).
channel_src="$(cd "$(dirname "$0")" && pwd)/lib/sudoers-automation-env"
if [ "$dry_run" -eq 1 ]; then
  log 'DRY-RUN: install sudoers automation-channel drop-in from shipped content + visudo check'
else
  [ -f "$channel_src" ] || { echo 'sudoers channel content missing from shipped lib (fail closed).' >&2; exit 2; }
  run install -m 440 /dev/null /etc/sudoers.d/99-automation-env
  cat "$channel_src" >/etc/sudoers.d/99-automation-env
  chmod 440 /etc/sudoers.d/99-automation-env
  visudo -cf /etc/sudoers.d/99-automation-env || { echo 'sudoers drop-in failed validation (fail closed).' >&2; exit 2; }
fi

if ! swapon --show 2>/dev/null | grep -q .; then
  run fallocate -l "$swap_size" /swapfile
  run chmod 600 /swapfile
  run mkswap /swapfile
  run swapon /swapfile
  if [ "$dry_run" -eq 1 ]; then
    log 'DRY-RUN: persist swap in /etc/fstab and set vm.swappiness=10'
  else
    grep -q '^/swapfile none swap sw 0 0$' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
    printf 'vm.swappiness=10\n' >/etc/sysctl.d/99-swap.conf
    sysctl --system >/dev/null
  fi
fi

run systemctl enable --now unattended-upgrades || true

if ! command -v docker >/dev/null 2>&1; then
  if [ "$dry_run" -eq 1 ]; then
    log 'DRY-RUN: install Docker Engine from the official apt repository when absent, then verify'
  else
    log 'Docker absent; installing Docker Engine from the official repository.'
    run apt-get install -y --no-install-recommends gnupg lsb-release
    run mkdir -p --mode=0755 /etc/apt/keyrings
    run bash -c 'curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg'
    run chmod a+r /etc/apt/keyrings/docker.gpg
    run bash -c 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list >/dev/null'
    run apt-get update -qq
    run apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    command -v docker >/dev/null 2>&1 || { echo 'Docker engine not installable on this release (Coolify requires Docker).' >&2; exit 2; }
    log 'Docker Engine installed from the official repository.'
  fi
else
  run docker version --format '{{.Server.Version}}'
  if [ "$dry_run" -eq 1 ]; then
    log 'DRY-RUN: docker run --rm hello-world'
  else
    run docker run --rm hello-world >/dev/null
  fi
  log 'Docker engine verified (hello-world ran successfully).'
fi

log 'bootstrap ready: guest packages, key-only SSH, swap, and time configured.'
if [ -f /var/run/reboot-required ] && [ "${BOOTSTRAP_ALLOW_REBOOT:-0}" = '1' ] && [ "$dry_run" -eq 0 ]; then
  log 'reboot required and explicitly allowed; rebooting.'
  reboot
fi
