#!/usr/bin/env bash
set -u

# Read-only health summary for the OVH/Coolify host.
# This script intentionally does not mutate packages, Docker, firewall or Coolify.

echo '== timestamp =='
date -Is

echo
echo '== operating system =='
cat /etc/os-release 2>/dev/null | grep -E '^(PRETTY_NAME|VERSION_ID)=' || true
uname -a

echo
echo '== uptime / load =='
uptime

echo
echo '== cpu =='
printf 'logical CPUs: '
nproc

echo
echo '== memory / swap =='
free -h
swapon --show || true
printf 'swappiness: '
sysctl -n vm.swappiness 2>/dev/null || echo 'unknown'

echo
echo '== filesystems =='
df -hT

echo
echo '== block devices =='
lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS

echo
echo '== failed systemd units =='
systemctl --failed --no-pager || true

echo
echo '== listening sockets =='
if [ "$(id -u)" -eq 0 ]; then
  ss -lntup || true
else
  sudo -n ss -lntup 2>/dev/null || ss -lnt || true
fi

echo
echo '== cloudflare tunnel =='
if command -v cloudflared >/dev/null 2>&1; then
  cloudflared --version || true
  if systemctl list-unit-files cloudflared.service >/dev/null 2>&1; then
    systemctl is-active cloudflared.service || true
    systemctl status cloudflared.service --no-pager -n 10 || true
  else
    echo 'cloudflared installed but cloudflared.service not found'
  fi
else
  echo 'cloudflared not installed'
fi

echo
echo '== docker =='
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    echo
    docker system df
    echo
    docker stats --no-stream || true
  elif sudo -n docker info >/dev/null 2>&1; then
    sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    echo
    sudo docker system df
    echo
    sudo docker stats --no-stream || true
  else
    echo 'docker installed but current user cannot query daemon without interactive sudo'
  fi
else
  echo 'docker not installed'
fi

echo
echo '== coolify =='
if [ -d /data/coolify ]; then
  echo '/data/coolify exists'
  if [ -f /data/coolify/source/.env ]; then
    echo 'Coolify .env exists (contents intentionally not printed)'
  else
    echo 'WARNING: /data/coolify/source/.env not found'
  fi
  du -sh /data/coolify 2>/dev/null || true
else
  echo 'Coolify not installed at /data/coolify'
fi

echo
echo '== coolify realtime websocket =='
# The dashboard dials wss://<host>/app/<key> (same-origin 443); the tunnel
# fans /app/* to :6001 and /terminal/ws* to :6002 (see infra ingress).
# A 101 here proves the realtime container answers WS handshakes.
AID=''
if command -v docker >/dev/null 2>&1; then
  AID=$(docker exec coolify-realtime printenv SOKETI_DEFAULT_APP_ID 2>/dev/null || true)
fi
if [ -n "$AID" ]; then
  printf 'WS upgrade /app/<key> on :6001 => '
  curl -s -o /dev/null -w '%{http_code}\n' --max-time 8 --http1.1 \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    "http://127.0.0.1:6001/app/$AID?protocol=7&client=js&version=8&flash=false" || echo 'FAILED'
else
  echo 'WARNING: could not read Soketi app id (realtime container down?)'
fi
AID=''

echo '== coolify proxy version =='
# Coolify manages the proxy image; the dashboard warns on newer minor
# branches (traefik_outdated_info). Drift here means a pending upgrade.
if command -v docker >/dev/null 2>&1; then
  docker inspect coolify-proxy --format 'proxy image: {{.Config.Image}}' 2>/dev/null || echo 'WARNING: coolify-proxy not found'
else
  echo 'docker unavailable'
fi

echo '== recent OOM indicators =='
if [ "$(id -u)" -eq 0 ]; then
  journalctl -k --since '24 hours ago' --no-pager 2>/dev/null | grep -i -E 'oom|out of memory|killed process' || echo 'none found'
else
  sudo -n journalctl -k --since '24 hours ago' --no-pager 2>/dev/null | grep -i -E 'oom|out of memory|killed process' || echo 'none found or unavailable'
fi

echo
echo '== reboot required =='
if [ -f /var/run/reboot-required ]; then
  cat /var/run/reboot-required
else
  echo 'no'
fi

echo
echo 'Health check complete.'
