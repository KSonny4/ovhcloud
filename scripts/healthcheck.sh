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
echo '== tailscale =='
if command -v tailscale >/dev/null 2>&1; then
  tailscale status || true
  printf 'tailscale IPv4: '
  tailscale ip -4 2>/dev/null || true
else
  echo 'tailscale not installed'
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
