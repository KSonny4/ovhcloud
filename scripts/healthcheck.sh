#!/usr/bin/env bash
set -u

# Read-only health summary for the OVH/Nomad host.
# This script intentionally does not mutate packages, Docker, firewall or Nomad.

echo '== timestamp =='
date -Is

echo
echo '== operating system =='
grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release 2>/dev/null || true
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
echo '== nomad =='
export NOMAD_ADDR='http://127.0.0.1:4646'
if command -v nomad >/dev/null 2>&1; then
  nomad server members 2>/dev/null || echo 'WARNING: no server members (agent down?)'
  nomad node status -short 2>/dev/null || echo 'WARNING: no client nodes (agent down?)'
  nomad --version 2>/dev/null || true
else
  echo 'WARNING: nomad not installed'
fi

echo
echo '== nomad leader endpoint (loopback) =='
# A 200 here proves the local agent answers; the edge check (via tunnel +
# service token) lives in verify-nomad-live.sh.
curl -s -o /dev/null -w 'leader endpoint: %{http_code}\n' --max-time 8 \
  http://127.0.0.1:4646/v1/status/leader || echo 'FAILED'

echo '== nomad jobs =='
if command -v nomad >/dev/null 2>&1; then
  nomad job status 2>/dev/null || echo 'job list needs a token or agent is down (see verify-nomad-live.sh)'
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
