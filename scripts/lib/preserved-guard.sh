#!/usr/bin/env bash
# Shared preserved-host guard for the OVHcloud/Coolify fresh-host tooling.
#
# Why a library, not two literal string comparisons: the preserved production
# VPS can be reached through many names — its OVH service hostname, its IPv4,
# its IPv6, a stale DNS alias, or any future address OVH assigns it. Comparing
# the operator-supplied target against two literals is bypassed by any
# alternate route to the same machine. This guard instead resolves the target
# to every address it can mean (A/AAAA + reverse DNS) and intersects that set
# with the preserved service identity (OVH service name plus the live IP set
# from the OVH API, with an embedded fallback). Any intersection refuses.
#
# Usage (all fresh-host scripts and the remote runner source this file):
#   GUARD_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   # shellcheck source=preserved-guard.sh
#   source "${GUARD_SCRIPT_DIR}/lib/preserved-guard.sh"
#   refuse_preserved_host "$target_host"   # exits 2 on match, 0 otherwise
#
# The guard never prints secrets; it prints only the matched identity class.

# Immutable OVH service identity of the preserved production VPS. The service
# name is assigned by OVH and cannot be repointed at another machine; the
# fallback IPs are a safety net used only when the OVH API is unreachable.
PRESERVED_SERVICE_NAME='vps-1525c977.vps.ovh.net'
PRESERVED_FALLBACK_IPS='57.129.155.203 2001:41d0:801:2000::3663'

# Explicit OVH CLI channel: every ovhcloud invocation in this repo goes
# through ovh_cli, which builds a throwaway HOME containing a config written
# ONLY from OpenBao-derived environment (OVH_ENDPOINT/OVH_APPLICATION_KEY/
# OVH_APPLICATION_SECRET/OVH_CONSUMER_KEY). The ambient ~/.ovh.conf is never
# read (HOME redirect), and a missing credential fails closed instead of
# silently falling back to ambient state.
ovh_cli() {
  if [ -z "${OVH_ENDPOINT:-}" ] || [ -z "${OVH_APPLICATION_KEY:-}" ] \
    || [ -z "${OVH_APPLICATION_SECRET:-}" ] || [ -z "${OVH_CONSUMER_KEY:-}" ]; then
    echo 'ovh_cli: OpenBao-derived OVH credentials missing from environment (refusing ambient config).' >&2
    return 2
  fi
  command -v ovhcloud >/dev/null 2>&1 || { echo 'ovhcloud CLI is required.' >&2; return 2; }
  local tmp_home
  tmp_home="$(mktemp -d /tmp/ovh-explicit-home.XXXXXX)" || return 2
  printf '[default]\nendpoint=%s\napplication_key=%s\napplication_secret=%s\nconsumer_key=%s\n' \
    "$OVH_ENDPOINT" "$OVH_APPLICATION_KEY" "$OVH_APPLICATION_SECRET" "$OVH_CONSUMER_KEY" >"${tmp_home}/.ovh.conf"
  chmod 600 "${tmp_home}/.ovh.conf"
  local rc=0 out
  out="$(HOME="$tmp_home" command ovhcloud "$@" 2>/dev/null)" || rc=$?
  rm -rf "$tmp_home"
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$out"
}

_preserved_ip_set() {
  # Prefer the live IP set from the OVH API via the explicit channel; when
  # no OpenBao-derived credentials are present, make NO ovhcloud call and
  # fall back to embedded values (name matching still applies).
  local ips=''
  if [ -n "${OVH_ENDPOINT:-}" ] && [ -n "${OVH_APPLICATION_KEY:-}" ] \
    && [ -n "${OVH_APPLICATION_SECRET:-}" ] && [ -n "${OVH_CONSUMER_KEY:-}" ]; then
    ips="$(ovh_cli vps ip list --service-name "$PRESERVED_SERVICE_NAME" --output json \
      | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    items = d if isinstance(d, list) else d.get("results", d.get("data", []))
    out = []
    for it in items:
        if isinstance(it, dict):
            for k in ("ip", "address", "ipAddress"):
                if it.get(k): out.append(str(it[k]))
        elif isinstance(it, str): out.append(it)
    print(" ".join(out))
except Exception:
    print("")' 2>/dev/null || true)"
  fi
  if [ -z "$ips" ]; then
    ips="$PRESERVED_FALLBACK_IPS"
  fi
  printf '%s' "$ips"
}

_target_addresses() {
  # Every address a target string can mean: the literal itself plus all
  # resolved A/AAAA results. Never fails (empty output means unresolvable).
  local target="$1"
  printf '%s\n' "$target"
  getent ahosts "$target" 2>/dev/null | awk '{print $1}' | sort -u || true
}

refuse_preserved_host() {
  local target="${1:-}"
  if [ -z "$target" ]; then
    echo 'preserved-host guard: empty target; refusing.' >&2
    return 2
  fi
  local lowered
  lowered="$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]')"

  # 1. Direct service-name match (case-insensitive).
  if [ "$lowered" = "$PRESERVED_SERVICE_NAME" ]; then
    echo "Refusing: target is the preserved OVH service ${PRESERVED_SERVICE_NAME}." >&2
    return 2
  fi

  # 2. Address intersection: resolve the target and compare against the
  #    preserved IP set. Catches alternate hostnames, raw IPs, and future
  #    addresses the API reports.
  local preserved_ips resolved
  preserved_ips="$(_preserved_ip_set)"
  resolved="$(_target_addresses "$target")"
  local ip hit
  for ip in $preserved_ips; do
    hit="$(printf '%s\n' "$resolved" | tr '[:upper:]' '[:lower:]' | grep -Fx -m1 "$(printf '%s' "$ip" | tr '[:upper:]' '[:lower:]')" || true)"
    if [ -n "$hit" ]; then
      echo "Refusing: target resolves to preserved production address ${hit}." >&2
      return 2
    fi
  done

  # 3. Reverse-DNS match: if the target's addresses reverse-resolve to the
  #    preserved service name, it is the same machine under another name.
  local addr rev
  while IFS= read -r addr; do
    [ -n "$addr" ] || continue
    case "$addr" in
      *.*|*:*) ;;
      *) continue ;;
    esac
    rev="$(getent hosts "$addr" 2>/dev/null | awk '{print $2}' | tr '[:upper:]' '[:lower:]' || true)"
    if [ -n "$rev" ] && { [ "$rev" = "$PRESERVED_SERVICE_NAME" ] || printf '%s' "$rev" | grep -qF "$PRESERVED_SERVICE_NAME"; }; then
      echo "Refusing: target reverse-resolves to preserved identity ${rev}." >&2
      return 2
    fi
  done <<<"$resolved"

  return 0
}

refuse_preserved_self() {
  # On-target check: refuse when THIS machine is the preserved VPS, regardless
  # of what target label invoked the script. Covers a lying TARGET variable.
  local self_names self_ips preserved_ips ip
  self_names="$(hostname -f 2>/dev/null; hostname 2>/dev/null; hostname -s 2>/dev/null || true)"
  self_ips="$(hostname -I 2>/dev/null || true)"
  preserved_ips="$(_preserved_ip_set)"
  local n
  for n in $self_names; do
    if [ "$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]')" = "$PRESERVED_SERVICE_NAME" ]; then
      echo "Refusing: this machine IS the preserved ${PRESERVED_SERVICE_NAME}." >&2
      return 2
    fi
  done
  # Compare case-insensitively (IPv6 hex may differ in case).
  local self_lower ip_lower
  self_lower=" $(printf '%s' "$self_ips" | tr '[:upper:]' '[:lower:]') "
  for ip in $preserved_ips; do
    ip_lower="$(printf '%s' "$ip" | tr '[:upper:]' '[:lower:]')"
    if printf '%s' "$self_lower" | grep -qF " ${ip_lower} "; then
      echo "Refusing: this machine holds preserved production address ${ip}." >&2
      return 2
    fi
  done
  return 0
}
