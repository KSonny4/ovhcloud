#!/usr/bin/env bash
# Noninteractive remote provisioning runner for a fresh Nomad host.
#
# This is the project runner/provider channel: instead of manually running
# local root scripts on the target (scp + ad-hoc ssh), the operator runs this
# ONE script and it executes the full chain remotely over SSH —
# bootstrap -> Nomad -> Tunnel/Access -> R2 backup schedule — with
# per-stage verification. All secrets come from OpenBao (via `bao` on this
# machine) or from explicitly supplied env; values are never printed, never
# committed, and travel to the target only through the encrypted SSH channel
# (base64 env blob evaluated inside each SSH command; memory-only both ends).
#
# Prerequisites (operator side):
# - `bao` authenticated against BAO_ADDR (default https://secrets.pkubelka.cz)
#   with read access to secret/projects/ovhcloud/*.
# - SSH access to PROVISION_SSH_USER@PROVISION_HOST. PROVISION_SSH_KEY may be
#   omitted: the runner then generates an ed25519 pair, escrows both halves
#   in OpenBao, and registers the public half at the OVH account (signed API
#   call) so API-ordered VPS installs pick it up automatically. The only
#   remaining manual step is the VPS order itself (payment-gated, operator).
# - NOMAD_VERSION defaults to the pinned release (2.0.6); NOMAD_GOSSIP_KEY
#   is generated + escrowed when absent (never stored here). No admin
#   password exists on this plane — ACL bootstrap runs inside the nomad stage.
#
# Usage:
#   BAO_ADDR=https://secrets.pkubelka.cz \
#   PROVISION_HOST=fresh-host.example PROVISION_ZONE=example.com \
#   PROVISION_SSH_USER=ubuntu PROVISION_SSH_KEY=~/.ssh/ovh_nomad_ed25519 \
#   bash scripts/run-remote-provision.sh [--dry-run] [--stages bootstrap,nomad,edge,backup]
set -euo pipefail

dry_run=0
generate_key_only=0
reinstall_with_key=0
confirm_fresh=0
stages='bootstrap,nomad,edge,backup'
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --stages) stages="$2"; shift 2 ;;
    --stages=*) stages="${1#--stages=}"; shift ;;
    --generate-key-only) generate_key_only=1; shift ;;
    --reinstall-with-key) reinstall_with_key=1; shift ;;
    --i-confirm-host-is-fresh) confirm_fresh=1; shift ;;
    -h|--help)
      echo 'usage: run-remote-provision.sh [--dry-run] [--stages ...] [--generate-key-only] [--reinstall-with-key --i-confirm-host-is-fresh]'
      exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() { printf '%s\n' "$*"; }
# Loads OVH_API from OpenBao into the ovh_cli channel variables (exported
# only when ALL four fields are present; a partial escrow exports nothing
# so no half-credentialed call is possible). Called before the
# preserved-host guard on live runs; dry-run never touches OpenBao.
load_ovh_credentials() {
  local ak ash ck ep
  ak="$(bao kv get -field=application_key secret/projects/ovhcloud/OVH_API 2>/dev/null || true)"
  ash="$(bao kv get -field=application_secret secret/projects/ovhcloud/OVH_API 2>/dev/null || true)"
  ck="$(bao kv get -field=consumer_key secret/projects/ovhcloud/OVH_API 2>/dev/null || true)"
  ep="$(bao kv get -field=endpoint secret/projects/ovhcloud/OVH_API 2>/dev/null || true)"
  if [ -n "$ak" ] && [ -n "$ash" ] && [ -n "$ck" ] && [ -n "$ep" ]; then
    export OVH_ENDPOINT="$ep" OVH_APPLICATION_KEY="$ak" OVH_APPLICATION_SECRET="$ash" OVH_CONSUMER_KEY="$ck"
  fi
}
run() {
  if [ "$dry_run" -eq 1 ]; then
    log "DRY-RUN: $*"
  else
    "$@"
  fi
}

host="${PROVISION_HOST:-}"
# Single explicit domain contract: the operator supplies the Cloudflare ZONE
# and the runner derives the UI hostname from it, so Nomad FQDN,
# Tunnel ingress/DNS, and every HTTP verification use the same hostname.
# (An earlier revision took a bare domain and configured https://${domain}
# while the tunnel verified the UI hostname — now impossible.)
zone="${PROVISION_ZONE:-}"
# Single-domain contract (no override): the UI hostname is always
# nomad.${PROVISION_ZONE}, matching the Terraform config and every
# verification URL. A removed PROVISION_UI_HOST fails closed.
if [ -n "${PROVISION_UI_HOST:-}" ]; then
  echo 'PROVISION_UI_HOST was removed: the UI hostname is always nomad.<PROVISION_ZONE> (single-domain contract with Terraform).' >&2
  exit 2
fi
if [ -n "${PROVISION_DASHBOARD_HOST:-}" ]; then
  echo 'PROVISION_DASHBOARD_HOST was removed: use the nomad.<PROVISION_ZONE> contract (no override).' >&2
  exit 2
fi
ui_host=""
if [ -n "$zone" ]; then
  ui_host="nomad.${zone}"
fi
ssh_user="${PROVISION_SSH_USER:-ubuntu}"
ssh_key="${PROVISION_SSH_KEY:-}"
cf_account="${CLOUDFLARE_ACCOUNT_ID:-5eb3ea3a84b37564cfd8739f32ffb559}"
cf_zone="${CLOUDFLARE_ZONE_ID:-0fcca39cc6516b8e23971bd717c0e9ca}"
nomad_version="${NOMAD_VERSION:-2.0.6}"
bao_addr="${BAO_ADDR:-https://secrets.pkubelka.cz}"
# Key-only minting precedes host selection by design (mint first, order the
# VPS with the printed key, then re-run with a host): it needs no target.
if [ "$generate_key_only" -eq 0 ] && { [ -z "$host" ] || [ -z "$zone" ] || [ -z "$ui_host" ]; }; then
  echo 'PROVISION_HOST and PROVISION_ZONE must be set (not required for --generate-key-only).' >&2
  exit 2
fi
# Operator-side identity guard: resolve the target against the preserved OVH
# service identity (API-backed when available) before any network/secret
# access. No self-check here by design: the runner never runs on the target.
GUARD_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/preserved-guard.sh
source "${GUARD_SCRIPT_DIR}/lib/preserved-guard.sh"
# OVH authorization precedes every ovhcloud touch: live runs load the
# OpenBao-derived channel BEFORE the guard (fail closed on bao errors via
# set -e); dry-run never touches OpenBao, so the guard makes no API call
# and decides on service name + embedded fallback addresses.
if [ "$dry_run" -eq 0 ]; then
  export BAO_ADDR="$bao_addr"
  load_ovh_credentials
fi
# No guard without a target: key-only minting names no host (nothing to
# refuse); every host-bearing path still refuses the preserved identity.
if [ -n "$host" ]; then refuse_preserved_host "$host" || exit 2; fi
# SSH credentials are OpenBao-managed: a supplied key is used as-is, otherwise
# the runner generates an ed25519 pair and escrows both halves (fail closed).
# The public half is then registered at the OVH account via signed API call so
# any VPS installed afterwards picks it up (idempotent by key name).
generated_key_dir=''
ssh_pub_file=''
derived_pub_file=''
key_generated=0
# Live-only credential preparation runs after the dry-run early exit below;
# dry-run logs the plan without generating keys or touching OVH/OpenBao.
prepare_operator_credentials() {
if [ -z "$ssh_key" ] || [ ! -e "$ssh_key" ]; then
  command -v ssh-keygen >/dev/null 2>&1 || { echo 'ssh-keygen is required to generate the SSH keypair.' >&2; exit 2; }
  generated_key_dir="$(mktemp -d /tmp/ovh-ssh-key.XXXXXX)"
  chmod 700 "$generated_key_dir"
  ssh-keygen -t ed25519 -N '' -C 'ovh-nomad-provisioning' -f "${generated_key_dir}/id_ed25519" >/dev/null
  # NOTE: the escrow paths are singletons — generating again replaces the
  # escrowed pair (previous targets keep working; only the OpenBao record
  # changes). Prefer PROVISION_SSH_KEY for additional hosts.
  if bao kv put -mount=secret projects/ovhcloud/PROVISION_SSH_PRIVATE_KEY value="@${generated_key_dir}/id_ed25519" >/dev/null 2>&1 \
    && bao kv put -mount=secret projects/ovhcloud/PROVISION_SSH_PUBLIC_KEY value="@${generated_key_dir}/id_ed25519.pub" >/dev/null 2>&1; then
    log 'generated SSH keypair escrowed to OpenBao (values never printed).'
  else
    echo 'SSH key escrow failed; refusing to continue.' >&2
    exit 2
  fi
  ssh_key="${generated_key_dir}/id_ed25519"
  ssh_pub_file="${generated_key_dir}/id_ed25519.pub"
  key_generated=1
else
  ssh_pub_file="${ssh_key}.pub"
  if [ ! -f "$ssh_pub_file" ]; then
    derived_pub_file="$(mktemp /tmp/ovh-ssh-derived.XXXXXX.pub)"
    ssh_pub_file="$derived_pub_file"
    ssh-keygen -y -f "$ssh_key" > "$ssh_pub_file" 2>/dev/null \
      || { echo 'cannot derive public key from PROVISION_SSH_KEY.' >&2; exit 2; }
  fi
fi

# Register the public key at the OVH account (signed API call, idempotent by
# name) so VPS installs pick it up. OVH applies account keys at install time;
# first-boot injection for an API-ordered VPS is therefore automatic, and the
# only remaining manual step is the order itself (payment-gated, operator).
# OVH key name derives from the public-key fingerprint: deterministic per key
# (idempotent, no litter) and distinct across rotations.
# OVH key names allow alphanumerics/dashes only: strip the SHA256: prefix and
# any base64 symbols, lowercase for tidiness.
key_fingerprint="$(ssh-keygen -lf "$ssh_pub_file" 2>/dev/null | awk '{print $2}' | tr -cd 'a-zA-Z0-9' | cut -c1-16 | tr '[:upper:]' '[:lower:]')"
if [ -z "$key_fingerprint" ]; then echo 'cannot fingerprint the SSH public key.' >&2; exit 2; fi
# OVH authorization arrives ONLY from OpenBao (OVH_API entry) via environment;
# the ambient OVH credential file is never read: every ovhcloud invocation
# goes through ovh_cli (explicit HOME-redirected config), and the guard
# makes no API call at all without these variables. Missing escrow fails
# closed when a generated key would be stranded; a supplied key stays
# operator-distributed.
# OVH channel state (exported by load_ovh_credentials before the guard on
# live runs; prepare reuses the same variables, never re-reads escrow).
if [ -n "${OVH_ENDPOINT:-}" ] && [ -n "${OVH_APPLICATION_KEY:-}" ] && [ -n "${OVH_APPLICATION_SECRET:-}" ] && [ -n "${OVH_CONSUMER_KEY:-}" ]; then
  OVH_KEY_NAME="ovh-nomad-${key_fingerprint}"
  export OVH_KEY_NAME OVH_PUB_FILE="$ssh_pub_file"
  python3 - <<'PY'
import hashlib, json, os, sys, time, urllib.request, urllib.error
try:
    ak, ash, ck = os.environ['OVH_APPLICATION_KEY'], os.environ['OVH_APPLICATION_SECRET'], os.environ['OVH_CONSUMER_KEY']
except KeyError as e:
    sys.exit(f'OVH credentials missing from environment, skipping account key registration: {e}')
def call(method, path, body=None):
    url = 'https://eu.api.ovh.com/1.0' + path
    data = json.dumps(body).encode() if body is not None else None
    now = str(int(time.time()))
    sig = '$1$' + hashlib.sha1((ash + '+' + ck + '+' + method + '+' + url + '+' + (json.dumps(body) if body else '') + '+' + now).encode()).hexdigest()
    req = urllib.request.Request(url, data=data, method=method, headers={
        'X-Ovh-Application': ak, 'X-Ovh-Consumer': ck, 'X-Ovh-Timestamp': now,
        'X-Ovh-Signature': sig, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        sys.exit(f'OVH API {method} {path} failed: HTTP {e.code}: {e.read().decode()[:150]}')
existing = call('GET', '/me/sshKey')
# The API returns a list of key-name strings (or, defensively, objects).
names = [(k.get('keyName') if isinstance(k, dict) else k) for k in existing] if isinstance(existing, list) else []
want = os.environ['OVH_KEY_NAME']
if want in names:
    print(f'OVH account key {want!r} already registered.')
else:
    pub = open(os.environ['OVH_PUB_FILE']).read().strip()
    call('POST', '/me/sshKey', {'key': pub, 'keyName': want})
    print(f'OVH account key {want!r} registered.')
PY
else
  # Fail closed only when skipping strands a freshly generated key (nothing
  # else could have distributed it). A supplied key stays operator-owned.
  if [ "$key_generated" -eq 1 ]; then
    echo 'OVH_API escrow incomplete in OpenBao; cannot register the generated key at OVH (fail closed).' >&2
    exit 2
  fi
  echo 'WARNING: OVH_API escrow incomplete in OpenBao; key registration skipped (supplied key stays operator-distributed).' >&2
fi
} # prepare_operator_credentials
log "target host: ${host} (user ${ssh_user})"
log "zone: ${zone}; UI hostname: ${ui_host}"
log "derived hostname used consistently for Nomad FQDN, Tunnel ingress/DNS, and every HTTP verification"
log "nomad version: ${nomad_version}"
log "stages: ${stages}"
log "dry run: ${dry_run}"

# ssh_opts is (re)built AFTER credential preparation: generation may replace
# an empty ssh_key, and a stale `-i ""` would break every remote stage.
ssh_opts=()
remote_dir='/tmp/ovh-provision'
remote_touched=0

cleanup_remote() {
  # Fail-safe: remove remote stage material (scripts only; credentials travel
  # memory-only inside each SSH command) on EVERY exit path, not just
  # success. Best-effort
  # by design — must never mask the real exit code — but a failure here is
  # loud so a leftover secret file cannot go unnoticed.
  if [ "$dry_run" -eq 1 ] || [ "$remote_touched" -eq 0 ]; then
    return 0
  fi
  # Client-side expansion is intentional: remote_dir is a runner-local constant.
  # shellcheck disable=SC2029
  if ssh "${ssh_opts[@]}" "${ssh_user}@${host}" "rm -rf ${remote_dir}" 2>/dev/null; then
    log 'remote stage material removed.'
  else
    echo "WARNING: could not remove remote stage material at ${host}:${remote_dir}; inspect manually." >&2
  fi
  return 0
}
# Local key material (generated private key, derived pubkey, env file) is
# shredded on every exit path; remote material via cleanup_remote above.
trap 'cleanup_remote; rm -f "$derived_pub_file"; [ -n "$generated_key_dir" ] && rm -rf "$generated_key_dir"; true' EXIT

want_stage() {
  case ",${stages}," in
    *,"$1",*) return 0 ;;
    *) return 1 ;;
  esac
}

if [ "$dry_run" -eq 1 ]; then
  log 'DRY-RUN: modes: --generate-key-only (mint+escrow+print pubkey, exit); --reinstall-with-key --i-confirm-host-is-fresh (OVH reinstall with key injected, DESTRUCTIVE); default probes SSH first and fails closed with deterministic guidance on miss'
  log 'DRY-RUN: verify SSH connectivity (ssh -BatchMode user@host true)'
  log 'DRY-RUN: prepare credentials (generate + escrow SSH keypair when absent, register OVH account key, retrieve OpenBao fields by name); generate + escrow gossip key when NOMAD_GOSSIP_KEY absent (fail closed)'
  log 'DRY-RUN: run ensure-tunnel.sh on the per-target secret path (existing escrow no-op, else create dedicated tunnel via API + escrow; preserved tunnel never touched) before credential retrieval'
  log 'DRY-RUN: run ensure-service-token.sh --ensure-only (create/escrow, verify deferred until post-wiring) before retrieval; full lifecycle with HTTP 200 verify after wiring'
  log 'DRY-RUN: install sudo automation channel (step 0, before any sudo -E stage: static env_keep content, no secrets)'
  log 'DRY-RUN: scp stage scripts (only) to /tmp/ovh-provision; credentials travel as a base64 env blob inside each SSH command (memory-only both ends)'
  want_stage bootstrap && log 'DRY-RUN: remote sudo BOOTSTRAP_TARGET_HOST/BOOTSTRAP_SSH_PUBLIC_KEY bash bootstrap-vps.sh + verify docker hello-world'
  want_stage nomad && log "DRY-RUN: remote sudo NOMAD_VERSION/NOMAD_GOSSIP_KEY bash provision-nomad.sh (binary + config + unit + ACL bootstrap gate) + verify origin leader + fetch bootstrap token over SSH and escrow operator-side (fail closed); runner cannot finish the nomad stage while bootstrap is unescrowed"
  if want_stage edge; then
    log 'DRY-RUN edge sequence (two-phase; readiness gates only after the connector runs):'
    log 'DRY-RUN edge 0/5: ensure-fresh-backend (generate backend.hcl: names/URLs only, refuse preserved key, AWS_* via memory-only env)'
    log 'DRY-RUN edge 1/5: wire --skip-verify (API wiring: ingress + DNS + Access, handoff; NO readiness gate)'
    log 'DRY-RUN edge 2/5: emit (generate fresh IaC) + adopt --apply (imports + zero-change plan assert)'
    log 'DRY-RUN edge 3/5: remote sudo TUNNEL_TARGET_HOST/TUNNEL_DOMAIN/CLOUDFLARED_TUNNEL_TOKEN/CF_ACCESS_* bash configure-tunnel-access.sh (connector install + start)'
    log 'DRY-RUN edge 4/5: ensure-service-token full (prove escrowed pair -> HTTP 200)'
    log 'DRY-RUN edge 5/5: wire --verify-only (UI 200 + ssh gated status)'
  fi
  want_stage backup && log 'DRY-RUN: ensure-omniroute-secrets.sh (generate-if-absent + escrow, reuse otherwise)'
  want_stage backup && log 'DRY-RUN: mint R2 reader token + place accessor (0600) via stdin pipe + remote sudo bash schedule-host-backup.sh (fetch-r2-env memory-only) + verify timer + R2 object'
  log 'DRY-RUN: remove remote stage scripts on every exit path; report per-stage pass/fail (fail closed)'
  exit 0
fi

command -v bao >/dev/null 2>&1 || { echo 'bao CLI is required on the operator machine.' >&2; exit 2; }
export BAO_ADDR="$bao_addr"
prepare_operator_credentials
ssh_opts=(-i "$ssh_key" -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)

# Mode 1: key minting only. Prints the PUBLIC key for install-time injection
# (order flow or manual install), then exits before any SSH attempt.
if [ "$generate_key_only" -eq 1 ]; then
  log 'key-only mode: public key below is escrowed; inject it at VPS order/install time, then re-run without this flag.'
  cat "$ssh_pub_file"
  exit 0
fi

# Mode 2: deterministic reinstall. An already-ordered (but empty) host gets a
# real reinstall with the escrowed/generated public key injected, so the
# first SSH afterwards is guaranteed. DESTRUCTIVE by design: requires the
# explicit freshness confirmation and refuses the preserved host (guarded at
# the top of this script as well as inside every stage script).
if [ "$reinstall_with_key" -eq 1 ]; then
  [ "$confirm_fresh" -eq 1 ] || { echo '--reinstall-with-key requires --i-confirm-host-is-fresh (reinstall DESTROYS host data).' >&2; exit 2; }
  ovh_service="${PROVISION_OVH_SERVICE:-}"
  [ -n "$ovh_service" ] || { echo 'PROVISION_OVH_SERVICE (OVH VPS service name) is required for reinstall mode.' >&2; exit 2; }
  # Service-level preserved guard: a hostname can alias, a service name cannot.
  if [ "$(printf '%s' "$ovh_service" | tr '[:upper:]' '[:lower:]')" = "$PRESERVED_SERVICE_NAME" ]; then
    echo "Refusing: reinstall target is the preserved OVH service ${PRESERVED_SERVICE_NAME}." >&2
    exit 2
  fi
  # Reinstall authenticates through ovh_cli (OpenBao escrow via an explicit
  # HOME-redirected config; the ambient file is never read, fail closed).
  load_ovh_credentials
  if [ -z "${OVH_APPLICATION_KEY:-}" ] || [ -z "${OVH_APPLICATION_SECRET:-}" ] || [ -z "${OVH_CONSUMER_KEY:-}" ] || [ -z "${OVH_ENDPOINT:-}" ]; then
    echo 'OVH_API escrow incomplete in OpenBao; cannot reinstall (fail closed).' >&2
    exit 2
  fi
  image_id="${PROVISION_IMAGE_ID:-}"
  if [ -z "$image_id" ]; then
    log 'resolving newest Ubuntu LTS image for the service...'
    image_id="$(ovh_cli vps image list "$ovh_service" -o json | python3 -c 'import json,sys; imgs=[i for i in json.load(sys.stdin) if "Ubuntu" in str(i)]; print(sorted(imgs, key=lambda i: str(i.get("name",""), reverse=True))[0]["id"] if imgs else "")' || true)"
    [ -n "$image_id" ] || { echo 'no Ubuntu image found for the service; set PROVISION_IMAGE_ID explicitly.' >&2; exit 2; }
  fi
  log "reinstalling ${ovh_service} with image ${image_id} + injected SSH key (DESTRUCTIVE, confirmed fresh)..."
  run ovh_cli vps reinstall "$ovh_service" --image-id "$image_id" --public-ssh-key "$(cat "$ssh_pub_file")" --do-not-send-password --wait
  log 'reinstall complete; connector key injected at install time.'
fi

# Gossip key is OpenBao-managed end to end: an operator value takes
# precedence, otherwise the runner generates a key and escrows it (fail
# closed when escrow is unavailable). The ACL token is escrowed after the
# nomad stage bootstraps (patch-merge into the same entry).
if [ -z "${NOMAD_GOSSIP_KEY:-}" ]; then
  command -v openssl >/dev/null 2>&1 || { echo 'openssl is required to generate the gossip key.' >&2; exit 2; }
  NOMAD_GOSSIP_KEY="$(openssl rand -base64 32)"
  if bao kv put -mount=secret projects/ovhcloud/NOMAD_BOOTSTRAP "gossip_key=${NOMAD_GOSSIP_KEY}" >/dev/null 2>&1; then
    log 'generated gossip key escrowed to OpenBao NOMAD_BOOTSTRAP (value never printed).'
  else
    echo 'gossip key escrow failed; refusing to continue.' >&2
    exit 2
  fi
fi
bao_get() { bao kv get "-field=$2" "secret/projects/ovhcloud/$1"; }
# ssh_keys_match <pubkey-file> <pubkey-string>: true when both carry
# identical key material (fingerprint comparison; empty/unparseable fails).
ssh_keys_match() {
  local fp_file fp_str
  fp_file="$(ssh-keygen -l -f "$1" 2>/dev/null | awk '{print $2}')"
  fp_str="$(printf '%s' "$2" | ssh-keygen -l -f /dev/stdin 2>/dev/null | awk '{print $2}')"
  [ -n "$fp_file" ] && [ -n "$fp_str" ] && [ "$fp_file" = "$fp_str" ]
}

log 'checking SSH connectivity (first-access probe)...'
if ssh "${ssh_opts[@]}" "${ssh_user}@${host}" true 2>/dev/null; then
  log 'SSH connectivity ok.'
else
  # Deterministic first access: an OVH account key registered AFTER a host
  # was installed is NOT retroactively injected, so a failed probe with a
  # fresh key is expected — never proceed hoping. Two deterministic paths:
  if [ "$key_generated" -eq 1 ]; then
    echo "SSH probe failed for ${ssh_user}@${host} with the freshly generated key." >&2
    echo 'This is expected when the host was installed before the key existed.' >&2
    echo 'Deterministic options (pick one, then re-run):' >&2
    echo '  1. Order/install the VPS with the escrowed public key (already registered at OVH).' >&2
    echo '  2. Re-run with --reinstall-with-key --i-confirm-host-is-fresh (+ PROVISION_OVH_SERVICE) to reinstall this EMPTY host with the key injected.' >&2
    exit 2
  fi
  echo "SSH probe failed for ${ssh_user}@${host} with the supplied key (fail closed)." >&2
  exit 2
fi

# Tunnel lifecycle first (operator side, OpenBao-complete): an existing
# escrow is a no-op; a missing one is created via API + escrowed BEFORE any
# stage consumes it, so fresh provisioning never depends on dashboard-made
# secrets. R2 keys stay dashboard-gated (API issuance 403/404, documented).
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tunnel_slug="$(printf '%s' "$host" | tr -c 'a-zA-Z0-9-' '-' | tr '[:upper:]' '[:lower:]')"
# Dedicated tunnel identity per fresh target: the name defaults per-host and
# the secret path derives from it, so a fresh target can NEVER consume the
# preserved tunnel's singleton escrow. The preserved tunnel name is refused.
tunnel_name="${TUNNEL_NAME:-nomad-${tunnel_slug}}"
if [ "$tunnel_name" = 'nomad-admin' ]; then
  echo 'Refusing: nomad-admin is the preserved tunnel; fresh targets get a dedicated tunnel.' >&2
  exit 2
fi
tunnel_secret_path="${TUNNEL_SECRET_PATH:-EDGE_TUNNEL_$(printf '%s' "$tunnel_name" | tr 'a-z-' 'A-Z_')}"
log "tunnel identity: ${tunnel_name} @ OpenBao ${tunnel_secret_path}"
log '== tunnel lifecycle (operator side) =='
run env BAO_ADDR="$bao_addr" CLOUDFLARE_ACCOUNT_ID="$cf_account" \
  TUNNEL_NAME="$tunnel_name" TUNNEL_SECRET_PATH="$tunnel_secret_path" \
  bash "$repo_root/scripts/ensure-tunnel.sh"

# First-time service-token flow: creation/escrow MUST precede any step that
# requires the pair (retrieval below, wire-fresh-edge.sh). Verification is
# deferred until the Access application and DNS route exist (full
# ensure-service-token.sh runs after wiring in the edge stage).
log '== service-token ensure-only (operator side, before any consumer) =='
run env BAO_ADDR="$bao_addr" CLOUDFLARE_ACCOUNT_ID="$cf_account" \
  bash "$repo_root/scripts/ensure-service-token.sh" --ensure-only

log 'retrieving stage credentials from OpenBao (names only, values never printed)...'
ssh_pub="$(bao_get PROVISION_SSH_PUBLIC_KEY value)"
tunnel_token="$(bao kv get -field=tunnel_token "secret/projects/ovhcloud/${tunnel_secret_path}")"
svc_id="$(bao_get EDGE_ACCESS_SERVICE_TOKEN client_id)"
svc_secret="$(bao_get EDGE_ACCESS_SERVICE_TOKEN client_secret)"
# R2 keys are deliberately NOT retrieved: the target pulls them memory-only
# via fetch-r2-env.sh, so operator-side handling cannot leak them.
for v in ssh_pub tunnel_token svc_id svc_secret; do
  if [ -z "${!v}" ]; then echo "OpenBao escrow missing for ${v}; refusing to continue." >&2; exit 2; fi
done
# The operator connects with PROVISION_SSH_KEY but the host is installed
# with the escrowed PROVISION_SSH_PUBLIC_KEY: when a key was supplied (not
# generated this run), the two must be identical, otherwise the operator
# would connect with one key while installing another (lockout risk).
if [ "${key_generated:-0}" != 1 ] && [ -n "${ssh_key:-}" ] && [ -f "${ssh_pub_file:-}" ]; then
  if ! ssh_keys_match "$ssh_pub_file" "$ssh_pub"; then
    echo 'PROVISION_SSH_KEY does not match escrowed PROVISION_SSH_PUBLIC_KEY; refusing to continue.' >&2
    echo 'Unset PROVISION_SSH_KEY to use the escrowed pair, or re-escrow the supplied key first.' >&2
    exit 2
  fi
  log 'supplied SSH key matches escrowed PROVISION_SSH_PUBLIC_KEY.'
fi
log 'OpenBao retrieval ok (all required fields present).'

# Preflight: fail FAST before any mutation when the single dashboard-gated
# prerequisite is missing. R2 S3 key issuance has no Cloudflare API route
# (verified: every r2/api_tokens path returns 10015; bucket management
# itself works), so BACKUP_R2 must be escrowed from a dashboard-minted key.
# Presence is checked by name only; values never leave OpenBao here.
if want_stage backup; then
  for f in access_key_id secret_access_key bucket endpoint; do
    if [ -z "$(bao kv get -field="$f" secret/projects/ovhcloud/BACKUP_R2 2>/dev/null || true)" ]; then
      echo "preflight: OpenBao BACKUP_R2.${f} missing (fail closed before mutating anything)." >&2
      echo 'R2 S3 keys cannot be minted via API (no route); mint in the dashboard:' >&2
      echo '  R2 -> Manage R2 API Tokens -> Object Read & Write scoped to the bucket,' >&2
      echo '  then escrow: bao kv put -mount=secret projects/ovhcloud/BACKUP_R2 access_key_id=... secret_access_key=... bucket=... endpoint=...' >&2
      exit 2
    fi
  done
  log 'preflight ok: BACKUP_R2 escrow present (values never retrieved here).'
fi

# NOTE: the single EXIT trap installed near the top covers generated keys +
# remote material on every path; do NOT install another here.
#
# Memory-only credential transport: stage values are shell-quoted, packed
# into one base64 blob, piped on stdin (never argv: invisible to ps), and
# evaluated inside each remote SSH command. Nothing credential-bearing touches
# disk on either end (an earlier stage.env file proved that any on-disk copy
# leaks through tooling). The remote shell exports the blob into process
# environment for `sudo -E`, which dies with the session. R2 keys are not in
# the blob at all: the target pulls them per-run via fetch-r2-env.sh.
qline() { printf 'export %s=%s\n' "$1" "$(printf '%s' "$2" | sed 's/[^A-Za-z0-9_.\/+=@:-]/\\&/g')"; }
remote_env_blob="$( { qline BOOTSTRAP_TARGET_HOST "$host"
  qline BOOTSTRAP_SSH_PUBLIC_KEY "$ssh_pub"
  qline NOMAD_VERSION "$nomad_version"
  qline NOMAD_GOSSIP_KEY "$NOMAD_GOSSIP_KEY"
  qline TUNNEL_TARGET_HOST "$host"
  qline TUNNEL_DOMAIN "$zone"
  qline CLOUDFLARED_TUNNEL_TOKEN "$tunnel_token"
  qline CF_ACCESS_CLIENT_ID "$svc_id"
  qline CF_ACCESS_CLIENT_SECRET "$svc_secret"; } | base64 )"

log 'copying stage scripts to the target (no credential files)...'
run ssh "${ssh_opts[@]}" "${ssh_user}@${host}" "mkdir -p ${remote_dir}/lib && chmod 700 ${remote_dir} ${remote_dir}/lib"
remote_touched=1
# Both backup scripts travel together: schedule-host-backup.sh fails closed
# on a clean host when its application-workload companion is absent.
run scp -p "${ssh_opts[@]}" "$repo_root/scripts/bootstrap-vps.sh" "$repo_root/scripts/provision-nomad.sh" \
  "$repo_root/scripts/configure-tunnel-access.sh" "$repo_root/scripts/schedule-host-backup.sh" \
  "$repo_root/scripts/backup-app-workloads.sh" "$repo_root/scripts/fetch-r2-env.sh" \
  "$repo_root/scripts/rollback-nomad-snapshot.sh" "$repo_root/scripts/rollback-app-workloads.sh" \
  "${ssh_user}@${host}:${remote_dir}/"
run scp -p "${ssh_opts[@]}" "$repo_root/scripts/lib/preserved-guard.sh" \
  "$repo_root/scripts/lib/sudoers-automation-env" \
  "$repo_root/scripts/lib/escrowed-app-envs" \
  "${ssh_user}@${host}:${remote_dir}/lib/"
# Step 0 — establish the sudo channel BEFORE any sudo -E stage. A fresh
# image has NOPASSWD without SETENV, so sudo -E is ignored until this
# policy lands; without it the first stage loses BOOTSTRAP_TARGET_HOST +
# BOOTSTRAP_SSH_PUBLIC_KEY (chicken-and-egg: bootstrap cannot install the
# policy it needs to receive its own variables). The content carries NO
# secrets (variable names only) and travels as the shipped static file on
# stdin; bootstrap re-applies the same file as convergence afterwards.
log 'establish sudo automation channel (step 0, before any sudo -E stage)'
run ssh "${ssh_opts[@]}" "${ssh_user}@${host}" \
  'sudo tee /etc/sudoers.d/99-automation-env >/dev/null && sudo chmod 440 /etc/sudoers.d/99-automation-env && sudo visudo -cf /etc/sudoers.d/99-automation-env' \
  <"$repo_root/scripts/lib/sudoers-automation-env"

remote_stage() {
  local name="$1" script="$2"
  log "== remote stage: ${name} =="
  # The credential blob travels on stdin (never in argv: invisible to ps on
  # both ends); the remote shell decodes it into session environment only.
  printf '%s' "$remote_env_blob" | run ssh "${ssh_opts[@]}" "${ssh_user}@${host}" \
    'eval "$(base64 -d)"; sudo -E bash '"${remote_dir}/${script}"
  log "remote stage ${name} exited 0."
}

if want_stage bootstrap; then
  remote_stage bootstrap bootstrap-vps.sh
  run ssh "${ssh_opts[@]}" "${ssh_user}@${host}" 'docker run --rm hello-world >/dev/null'
  log 'bootstrap verified: docker hello-world runs on the target.'
fi

if want_stage nomad; then
  # Capture stage output: the bootstrap escrow line travels back over the
  # encrypted channel and is escrowed operator-side below (memory-only).
  nomad_stage_out="$(printf '%s' "$remote_env_blob" | ssh "${ssh_opts[@]}" "${ssh_user}@${host}" \
    'eval "$(base64 -d)"; sudo -E bash '"${remote_dir}/provision-nomad.sh")"
  printf '%s\n' "$nomad_stage_out"
  log 'nomad provisioned on the target.'
  run ssh "${ssh_opts[@]}" "${ssh_user}@${host}" 'curl -fsS --max-time 20 http://127.0.0.1:4646/v1/status/leader -o /dev/null'
  log 'nomad verified: origin leader endpoint answers on the target.'
  # Authoritative bootstrap-token escrow (operator side, fail closed): the
  # fresh host has no bao CLI, so the runner captures the escrow line over
  # the encrypted channel and patch-merges it into NOMAD_BOOTSTRAP. The
  # token lives only in local variables, never on disk, and is cleared
  # immediately after escrow.
  escrow_line="$(printf '%s\n' "$nomad_stage_out" | grep '^NOMAD_BOOTSTRAP_ESCROW ' | head -n1 || true)"
  if [ -n "$escrow_line" ]; then
    escrow_secret="$(printf '%s' "$escrow_line" | sed -E 's/.*secret=([^ ]+).*/\1/')"
    escrow_accessor="$(printf '%s' "$escrow_line" | sed -E 's/.*accessor=([^ ]+).*/\1/')"
    export BAO_ADDR="$bao_addr"
    if [ -n "$escrow_secret" ] && [ -n "$escrow_accessor" ] \
      && bao kv patch -mount=secret projects/ovhcloud/NOMAD_BOOTSTRAP "acl_token=${escrow_secret}" "acl_accessor=${escrow_accessor}" >/dev/null 2>&1; then
      log 'escrowed ACL token + accessor to OpenBao NOMAD_BOOTSTRAP (values never printed).'
    else
      echo 'bootstrap token escrow write failed (fail closed).' >&2
      exit 2
    fi
    escrow_secret=''; escrow_accessor=''; escrow_line=''
  elif printf '%s\n' "$nomad_stage_out" | grep -q 'BOOTSTRAP_EXISTS'; then
    if [ -z "$(bao kv get -field=acl_token secret/projects/ovhcloud/NOMAD_BOOTSTRAP 2>/dev/null || true)" ]; then
      echo 'cluster already bootstrapped but no ACL token is escrowed; re-bootstrap or escrow manually (fail closed).' >&2
      exit 2
    fi
    log 'bootstrap already escrowed; cluster reports BOOTSTRAP_EXISTS.'
  else
    echo 'nomad stage emitted neither an escrow line nor BOOTSTRAP_EXISTS (fail closed).' >&2
    exit 2
  fi
  nomad_stage_out=''
  # Bootstrap gate (operator side, fail closed): prove the escrowed token
  # administers the fresh cluster. The token travels on stdin (never argv).
  escrowed_token="$(bao kv get -field=acl_token secret/projects/ovhcloud/NOMAD_BOOTSTRAP 2>/dev/null || true)"
  if [ -z "$escrowed_token" ]; then echo 'escrowed ACL token unreadable (fail closed).' >&2; exit 2; fi
  if printf '%s' "$escrowed_token" | ssh "${ssh_opts[@]}" "${ssh_user}@${host}" 'read -r NOMAD_TOKEN; export NOMAD_TOKEN; export NOMAD_ADDR=http://127.0.0.1:4646; nomad acl token self >/dev/null' 2>/dev/null; then
    log 'bootstrap gate passed: escrowed token administers the cluster.'
  else
    echo 'bootstrap gate failed: escrowed token rejected by the cluster (fail closed).' >&2
    exit 2
  fi
  escrowed_token=''
fi

if want_stage edge; then
  # Fresh-edge wiring (operator side): bind the escrowed tunnel identity to
  # the dashboard hostname (ingress + DNS, idempotent) BEFORE the connector
  # runs, then gate on HTTP 200. Without this a fresh tunnel has no route.
  # Tunnel identity: dedicated field when present (fresh ensure path), else
  # the "t" claim inside the JSON connector token (legacy escrow layout).
  tunnel_id="$(bao kv get -field=tunnel_id "secret/projects/ovhcloud/${tunnel_secret_path}" 2>/dev/null || true)"
  if [ -z "$tunnel_id" ]; then
    tunnel_id="$(printf '%s' "$tunnel_token" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("t",""))' 2>/dev/null || true)"
  fi
  if [ -z "$tunnel_id" ]; then echo 'tunnel identity unresolvable in OpenBao (ensure-tunnel must run first).' >&2; exit 2; fi
  # Two-phase edge contract: API wiring runs BEFORE the connector exists
  # (no traffic can flow yet), readiness verification runs AFTER the
  # connector is installed and started. Verifying before install fails on
  # every genuinely fresh host.
  log '== fresh-edge wiring (operator side, API only) =='
  # Backend BEFORE the first Cloudflare mutation: a clean checkout must
  # never wire edge resources it cannot adopt (partial-state failure).
  # backend.hcl carries no credentials (names/URLs only; S3 auth via
  # memory-only AWS_* env in adopt), so generating it is secrecy-safe.
  run env BAO_ADDR="$bao_addr" bash "$repo_root/scripts/ensure-fresh-backend.sh"
  handoff_file="${repo_root}/.fresh-handoff-${tunnel_slug}.json"
  run env BAO_ADDR="$bao_addr" CLOUDFLARE_ACCOUNT_ID="$cf_account" \
    CLOUDFLARE_ZONE_ID="$cf_zone" TUNNEL_ID="$tunnel_id" \
    EDGE_HOSTNAME="$ui_host" SSH_HOSTNAME="ssh.${zone}" \
    bash "$repo_root/scripts/wire-fresh-edge.sh" --skip-verify --handoff-file "$handoff_file"
  log "edge handoff recorded at ${handoff_file} (gitignored; feed to emit-fresh-imports.sh)."
  run env CLOUDFLARE_ACCOUNT_ID="$cf_account" CLOUDFLARE_ZONE_ID="$cf_zone" \
    bash "$repo_root/scripts/emit-fresh-imports.sh" --handoff "$handoff_file"
  log 'fresh IaC generated in infra/terraform-fresh (main.tf + imports.tf).'
  # Adopt into state NOW (not a later manual step): imports the API-created
  # resources and requires a zero-change second plan (fail closed on drift).
  run env BAO_ADDR="$bao_addr" CLOUDFLARE_ACCOUNT_ID="$cf_account" \
    CLOUDFLARE_ZONE_ID="$cf_zone" \
    bash "$repo_root/scripts/adopt-fresh-edge.sh" --handoff "$handoff_file" --apply
  remote_stage edge configure-tunnel-access.sh
  # Readiness verification AFTER the connector runs (operator side): the
  # token was created/escrowed before retrieval (ensure-only); now that the
  # connector serves traffic, the full lifecycle proves HTTP 200, then the
  # wire verify pass proves dashboard 200 + ssh gated status.
  log '== service-token lifecycle (operator side, post-connector verification) =='
  run env BAO_ADDR="$bao_addr" CLOUDFLARE_ACCOUNT_ID="$cf_account" \
    NOMAD_LEADER_URL="https://${ui_host}/v1/status/leader" \
    bash "$repo_root/scripts/ensure-service-token.sh"
  run env BAO_ADDR="$bao_addr" CLOUDFLARE_ACCOUNT_ID="$cf_account" \
    CLOUDFLARE_ZONE_ID="$cf_zone" TUNNEL_ID="$tunnel_id" \
    EDGE_HOSTNAME="$ui_host" SSH_HOSTNAME="ssh.${zone}" \
    bash "$repo_root/scripts/wire-fresh-edge.sh" --verify-only
fi

if want_stage backup; then
  # Application-secret lifecycle (noninteractive recovery without human
  # relay): ensure the OmniRoute-derived secrets exist in OpenBao BEFORE
  # anything is backed up, so manifests can mark them escrow-recoverable
  # and restore re-injects them from escrow automatically.
  run env BAO_ADDR="$bao_addr" bash "$repo_root/scripts/ensure-omniroute-secrets.sh"
  log 'application secrets ensured in OpenBao (generate-if-absent, reuse otherwise).'
  # Memory-only R2 delivery: the target never holds R2 keys. It holds one
  # least-privilege OpenBao accessor (0600, read-only on the R2 entry) and
  # pulls keys into process memory per run via fetch-r2-env.sh. Minted fresh
  # operator-side each run (self-cleaning: periodic TTL, documented rotation).
  log 'minting least-privilege R2 reader token (operator side)...'
  r2_reader_token="$(BAO_ADDR="$bao_addr" bao token create -policy=backup-r2-reader -period=720h -orphan -format=json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("auth",{}).get("client_token",""))')"
  if [ -z "$r2_reader_token" ]; then echo 'R2 reader token minting failed (fail closed).' >&2; exit 2; fi
  printf '%s' "$r2_reader_token" | run ssh "${ssh_opts[@]}" "${ssh_user}@${host}" \
    'sudo mkdir -p /root/host-backup && sudo tee /root/host-backup/openbao-token >/dev/null && sudo chmod 600 /root/host-backup/openbao-token'
  r2_reader_token=''
  log 'R2 accessor placed (0600); R2 keys stay memory-only via fetch-r2-env.sh.'
  run ssh "${ssh_opts[@]}" "${ssh_user}@${host}" "sudo bash ${remote_dir}/schedule-host-backup.sh"
  run ssh "${ssh_opts[@]}" "${ssh_user}@${host}" 'sudo systemctl is-enabled host-backup.timer | grep -q enabled'
  log 'backup verified: host-backup.timer enabled on the target (first backup runs during install).'
fi

trap - EXIT
cleanup_remote
log 'remote provisioning complete: all requested stages passed with verification; R2 keys never touched disk (memory-only OpenBao pull; sole file: least-privilege accessor token 0600).'
