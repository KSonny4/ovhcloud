#!/usr/bin/env bash
# Idempotent host firewall compensation for Docker's UFW bypass.
#
# Root cause: Docker publishes container ports via iptables rules that jump
# BEFORE UFW's INPUT chain, so UFW DENY entries never applied to the
# Coolify-infra ports (:80/:443/:8000/:8080/:6001/:6002) — external probes
# reached them despite "Status: active" + DENY. This script filters in
# Docker's own DOCKER-USER hook chain (the documented extension point that
# survives container churn):
#   1. established/related traffic is RETURNed first (status quo preserved),
#   2. anything else arriving on the external interface is DROPped.
# Containers stay reachable via loopback (cloudflared's origin dials) and
# inter-container networks. Host SSH (sshd via UFW ALLOW 22) and all
# outbound traffic are untouched.
#
# Usage (as root): ensure-docker-firewall.sh [--check-only|--install]
#   default: enforce rules now. --check-only: verify, exit 1 if absent.
#   --install: enforce + install/enable the boot unit (After=docker).
# Every failure exits nonzero with a message (fail-closed). EXT_IF env
# overrides the detected external interface (default route's device).
set -euo pipefail

mode="${1:-enforce}"
if [ "$(id -u)" -ne 0 ]; then echo 'must run as root (fail closed).' >&2; exit 2; fi
EXT_IF="${EXT_IF:-$(ip -4 route show default | awk '{print $5}' | head -n1)}"
[ -n "$EXT_IF" ] || { echo 'no default-route interface (fail closed).' >&2; exit 2; }

need_chain() { # $1=iptables|ip6tables
  "$1" -S DOCKER-USER >/dev/null 2>&1 || { echo "$1 DOCKER-USER chain absent (is Docker running?) (fail closed)." >&2; exit 2; }
}

rule_ok() { # $1=iptables|ip6tables $2..=rule spec
  local bin="$1"; shift
  "$bin" -C DOCKER-USER "$@" >/dev/null 2>&1
}

ensure_rule() { # $1=iptables|ip6tables $2=position-flag(-I|-A) $3..=rule spec
  local bin="$1" pos="$2"; shift 2
  if ! rule_ok "$bin" "$@"; then
    if [ "$mode" = '--check-only' ]; then echo "missing: $bin DOCKER-USER $* (fail closed)." >&2; return 1; fi
    "$bin" "$pos" DOCKER-USER "$@" || { echo "cannot insert: $bin DOCKER-USER $* (fail closed)." >&2; exit 2; }
  fi
}

install_unit() {
  cat > /etc/systemd/system/docker-firewall.service <<'UNIT'
[Unit]
Description=Drop external ingress to Docker-published ports (tunnel-only origin)
After=docker.service network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ensure-docker-firewall.sh enforce
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload || exit 2
  systemctl enable --now docker-firewall.service || exit 2
}

rc=0
for bin in iptables ip6tables; do
  command -v "$bin" >/dev/null 2>&1 || { echo "$bin missing (fail closed)." >&2; exit 2; }
  need_chain "$bin"
  ensure_rule "$bin" -I -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN || rc=1
  ensure_rule "$bin" -A -i "$EXT_IF" -j DROP || rc=1
done
if [ "$mode" = '--install' ]; then
  cp "$0" /usr/local/sbin/ensure-docker-firewall.sh
  chmod 755 /usr/local/sbin/ensure-docker-firewall.sh
  install_unit
fi
if [ "$mode" = '--check-only' ]; then
  [ "$rc" -eq 0 ] && echo "docker-firewall rules present (ext_if=$EXT_IF)."
  exit "$rc"
fi
echo "docker-firewall enforced (ext_if=$EXT_IF)."
