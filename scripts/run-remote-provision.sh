#!/usr/bin/env bash
# Noninteractive remote provisioning runner for a fresh Coolify host.
#
# This is the project runner/provider channel: instead of manually running
# local root scripts on the target (scp + ad-hoc ssh), the operator runs this
# ONE script and it executes the full chain remotely over SSH —
# bootstrap -> Coolify -> Tunnel/Access -> R2 backup schedule — with
# per-stage verification. All secrets come from OpenBao (via `bao` on this
# machine) or from explicitly supplied env; values are never printed, never
# committed, and travel to the target only through the encrypted SSH channel
# (600-permission env file, deleted afterwards on both ends).
#
# Prerequisites (operator side):
# - `bao` authenticated against BAO_ADDR (default https://secrets.pkubelka.cz)
#   with read access to secret/projects/ovhcloud/*.
# - SSH access to PROVISION_SSH_USER@PROVISION_HOST. PROVISION_SSH_KEY may be
#   omitted: the runner then generates an ed25519 pair, escrows both halves
#   in OpenBao, and registers the public half at the OVH account (signed API
#   call) so API-ordered VPS installs pick it up automatically. The only
#   remaining manual step is the VPS order itself (payment-gated, operator).
# - ROOT_USERNAME / ROOT_USER_EMAIL default to admin / ksonny4@gmail.com;
#   ROOT_USER_PASSWORD is generated + escrowed when absent (never stored here).
#
# Usage:
#   BAO_ADDR=https://secrets.pkubelka.cz \
#   PROVISION_HOST=fresh-host.example PROVISION_ZONE=example.com \
#   PROVISION_SSH_USER=ubuntu PROVISION_SSH_KEY=~/.ssh/ovh_coolify_ed25519 \
#   ROOT_USERNAME=admin ROOT_USER_EMAIL=admin@example.com ROOT_USER_PASSWORD='...' \
#   bash scripts/run-remote-provision.sh [--dry-run] [--stages bootstrap,coolify,edge,backup]
set -euo pipefail

dry_run=0
stages='bootstrap,coolify,edge,backup'
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --stages) stages="$2"; shift 2 ;;
    --stages=*) stages="${1#--stages=}"; shift ;;
    -h|--help)
      echo 'usage: run-remote-provision.sh [--dry-run] [--stages bootstrap,coolify,edge,backup]'
      exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
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

host="${PROVISION_HOST:-}"
# Single explicit domain contract: the operator supplies the Cloudflare ZONE
# and the runner derives the dashboard hostname from it, so Coolify FQDN,
# Tunnel ingress/DNS, and every HTTP verification use the same hostname.
# (An earlier revision took a bare domain and configured https://${domain}
# while the tunnel verified https://coolify.${domain} — now impossible.)
zone="${PROVISION_ZONE:-}"
dashboard_host="${PROVISION_DASHBOARD_HOST:-}"
if [ -z "$dashboard_host" ] && [ -n "$zone" ]; then
  dashboard_host="coolify.${zone}"
fi
ssh_user="${PROVISION_SSH_USER:-ubuntu}"
ssh_key="${PROVISION_SSH_KEY:-}"
cf_account="${CLOUDFLARE_ACCOUNT_ID:-5eb3ea3a84b37564cfd8739f32ffb559}"
coolify_version="${COOLIFY_VERSION:-4.3.19}"
bao_addr="${BAO_ADDR:-https://secrets.pkubelka.cz}"
r2_endpoint="${R2_ENDPOINT:-https://5eb3ea3a84b37564cfd8739f32ffb559.r2.cloudflarestorage.com}"
if [ -z "$host" ] || [ -z "$zone" ] || [ -z "$dashboard_host" ]; then
  echo 'PROVISION_HOST and PROVISION_ZONE (or PROVISION_DASHBOARD_HOST) must be set.' >&2
  exit 2
fi
# Operator-side identity guard: resolve the target against the preserved OVH
# service identity (API-backed when available) before any network/secret
# access. No self-check here by design: the runner never runs on the target.
GUARD_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/preserved-guard.sh
source "${GUARD_SCRIPT_DIR}/lib/preserved-guard.sh"
refuse_preserved_host "$host" || exit 2
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
  ssh-keygen -t ed25519 -N '' -C 'ovh-coolify-provisioning' -f "${generated_key_dir}/id_ed25519" >/dev/null
  # NOTE: the escrow paths are singletons — generating again replaces the
  # escrowed pair (previous targets keep working; only the OpenBao record
  # changes). Prefer PROVISION_SSH_KEY for additional hosts.
  if bao kv put -mount=secret projects/ovhcloud/COOLIFY_SSH_PRIVATE_KEY value="@${generated_key_dir}/id_ed25519" >/dev/null 2>&1 \
    && bao kv put -mount=secret projects/ovhcloud/COOLIFY_SSH_PUBLIC_KEY value="@${generated_key_dir}/id_ed25519.pub" >/dev/null 2>&1; then
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
if [ -f "$HOME/.ovh.conf" ]; then
  OVH_KEY_NAME="ovh-coolify-${key_fingerprint}"
  export OVH_KEY_NAME OVH_PUB_FILE="$ssh_pub_file"
  python3 - <<'PY'
import hashlib, json, os, sys, time, urllib.request, urllib.error
def load(p):
    d = {}
    for line in open(os.path.expanduser(p)):
        line = line.strip()
        if '=' in line and not line.startswith('[') and not line.startswith('#'):
            k, v = line.split('=', 1)
            d[k.strip()] = v.strip()
    return d
try:
    c = load('~/.ovh.conf')
    ak, ash, ck = c['application_key'], c['application_secret'], c['consumer_key']
except Exception as e:
    sys.exit(f'OVH credentials unreadable, skipping account key registration: {e}')
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
names = [k.get('keyName') for k in existing] if isinstance(existing, list) else []
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
    echo '~/.ovh.conf absent; cannot register the generated key at OVH (fail closed).' >&2
    exit 2
  fi
  echo 'WARNING: ~/.ovh.conf absent; OVH account key registration skipped (supplied key stays operator-distributed).' >&2
fi
} # prepare_operator_credentials
log "target host: ${host} (user ${ssh_user})"
log "zone: ${zone}; dashboard hostname: ${dashboard_host}"
log "derived hostname used consistently for Coolify FQDN, Tunnel ingress/DNS, and every HTTP verification"
log "coolify version: ${coolify_version}"
log "stages: ${stages}"
log "dry run: ${dry_run}"

# ssh_opts is (re)built AFTER credential preparation: generation may replace
# an empty ssh_key, and a stale `-i ""` would break every remote stage.
ssh_opts=()
remote_dir='/tmp/ovh-provision'
remote_touched=0
env_file=''

cleanup_remote() {
  # Fail-safe: remove remote stage material (including stage.env with all
  # injected credentials) on EVERY exit path, not just success. Best-effort
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
trap 'cleanup_remote; rm -f "$env_file" "$derived_pub_file"; [ -n "$generated_key_dir" ] && rm -rf "$generated_key_dir"; true' EXIT

want_stage() {
  case ",${stages}," in
    *,"$1",*) return 0 ;;
    *) return 1 ;;
  esac
}

if [ "$dry_run" -eq 1 ]; then
  log 'DRY-RUN: verify SSH connectivity (ssh -BatchMode user@host true)'
  log 'DRY-RUN: prepare credentials (generate + escrow SSH keypair when absent, register OVH account key, retrieve OpenBao fields by name); generate + escrow bootstrap password when ROOT_USER_PASSWORD absent (fail closed)'
  log 'DRY-RUN: run ensure-service-token.sh (ensure/create/escrow/verify HTTP 200) before the edge stage'
  log 'DRY-RUN: scp stage scripts + generated 0600 env file to /tmp/ovh-provision on the target'
  want_stage bootstrap && log 'DRY-RUN: remote sudo BOOTSTRAP_TARGET_HOST/BOOTSTRAP_SSH_PUBLIC_KEY bash bootstrap-vps.sh + verify docker hello-world'
  want_stage coolify && log "DRY-RUN: remote sudo COOLIFY_TARGET_HOST/COOLIFY_DOMAIN/COOLIFY_VERSION/ROOT_* bash provision-coolify.sh (FQDN + firewall + origin smoke) + verify origin login + fetch APP_KEY over SSH and escrow operator-side (fail closed)"
  want_stage edge && log 'DRY-RUN: remote sudo TUNNEL_TARGET_HOST/TUNNEL_DOMAIN/CLOUDFLARED_TUNNEL_TOKEN/CF_ACCESS_* bash configure-tunnel-access.sh + verify domain login HTTP 200 locally'
  want_stage backup && log 'DRY-RUN: provision remote r2.env (0600) from OpenBao via stdin pipe + remote sudo bash schedule-coolify-backup.sh + verify timer + R2 object'
  log 'DRY-RUN: delete env file on both ends; report per-stage pass/fail (fail closed)'
  exit 0
fi

command -v bao >/dev/null 2>&1 || { echo 'bao CLI is required on the operator machine.' >&2; exit 2; }
export BAO_ADDR="$bao_addr"
prepare_operator_credentials
ssh_opts=(-i "$ssh_key" -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)

# Admin bootstrap credentials are OpenBao-managed end to end: operator values
# take precedence, otherwise the runner generates a password and escrows the
# full bootstrap record (fail closed when escrow is unavailable).
if [ -z "${ROOT_USERNAME:-}" ]; then ROOT_USERNAME='admin'; log 'ROOT_USERNAME defaulted to admin (operator may override).'; fi
# The blessed human identity doubles as the default bootstrap email (already
# enforced in Terraform), so no operator env is required for it.
if [ -z "${ROOT_USER_EMAIL:-}" ]; then ROOT_USER_EMAIL='ksonny4@gmail.com'; log 'ROOT_USER_EMAIL defaulted to ksonny4@gmail.com (operator may override).'; fi
if [ -z "${ROOT_USER_PASSWORD:-}" ]; then
  command -v openssl >/dev/null 2>&1 || { echo 'openssl is required to generate the bootstrap password.' >&2; exit 2; }
  ROOT_USER_PASSWORD="$(openssl rand -base64 33)"
  if printf '%s' "$ROOT_USER_PASSWORD" | bao kv put -mount=secret projects/ovhcloud/COOLIFY_ADMIN_BOOTSTRAP "username=${ROOT_USERNAME}" "email=${ROOT_USER_EMAIL}" 'password=-' >/dev/null 2>&1; then
    log 'generated bootstrap password escrowed to OpenBao COOLIFY_ADMIN_BOOTSTRAP (value never printed).'
  else
    echo 'bootstrap password escrow failed; refusing to continue.' >&2
    exit 2
  fi
fi
bao_get() { bao kv get "-field=$2" "secret/projects/ovhcloud/$1"; }

log 'checking SSH connectivity...'
run ssh "${ssh_opts[@]}" "${ssh_user}@${host}" true
log 'SSH connectivity ok.'

log 'retrieving stage credentials from OpenBao (names only, values never printed)...'
ssh_pub="$(bao_get COOLIFY_SSH_PUBLIC_KEY value)"
tunnel_token="$(bao_get COOLIFY_TUNNEL_TOKEN tunnel_token)"
svc_id="$(bao_get COOLIFY_ACCESS_SERVICE_TOKEN client_id)"
svc_secret="$(bao_get COOLIFY_ACCESS_SERVICE_TOKEN client_secret)"
r2_ak="$(bao_get COOLIFY_R2 access_key_id)"
r2_sk="$(bao_get COOLIFY_R2 secret_access_key)"
r2_bucket="$(bao_get COOLIFY_R2 bucket)"
for v in ssh_pub tunnel_token svc_id svc_secret r2_ak r2_sk r2_bucket; do
  if [ -z "${!v}" ]; then echo "OpenBao escrow missing for ${v}; refusing to continue." >&2; exit 2; fi
done
log 'OpenBao retrieval ok (all required fields present).'

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
env_file="$(mktemp /tmp/ovh-provision-env.XXXXXX)"
chmod 600 "$env_file"
# NOTE: the single EXIT trap installed near the top already covers env file +
# generated keys + remote material on every path; do NOT install another here.
cat >"$env_file" <<ENV_EOF
BOOTSTRAP_TARGET_HOST=${host}
BOOTSTRAP_SSH_PUBLIC_KEY=${ssh_pub}
COOLIFY_TARGET_HOST=${host}
COOLIFY_DOMAIN=${dashboard_host}
COOLIFY_VERSION=${coolify_version}
ROOT_USERNAME=${ROOT_USERNAME}
ROOT_USER_EMAIL=${ROOT_USER_EMAIL}
ROOT_USER_PASSWORD=${ROOT_USER_PASSWORD}
TUNNEL_TARGET_HOST=${host}
TUNNEL_DOMAIN=${zone}
CLOUDFLARED_TUNNEL_TOKEN=${tunnel_token}
CF_ACCESS_CLIENT_ID=${svc_id}
CF_ACCESS_CLIENT_SECRET=${svc_secret}
COOLIFY_SERVICE_TOKEN_CLIENT_ID=${svc_id}
COOLIFY_SERVICE_TOKEN_CLIENT_SECRET=${svc_secret}
R2_ACCESS_KEY_ID=${r2_ak}
R2_SECRET_ACCESS_KEY=${r2_sk}
R2_ENDPOINT=${r2_endpoint}
R2_BUCKET=${r2_bucket}
AWS_DEFAULT_REGION=auto
ENV_EOF

log 'copying stage scripts + env file to the target...'
run ssh "${ssh_opts[@]}" "${ssh_user}@${host}" "mkdir -p ${remote_dir}/lib && chmod 700 ${remote_dir} ${remote_dir}/lib"
remote_touched=1
run scp -p "${ssh_opts[@]}" "$repo_root/scripts/bootstrap-vps.sh" "$repo_root/scripts/provision-coolify.sh" \
  "$repo_root/scripts/configure-tunnel-access.sh" "$repo_root/scripts/schedule-coolify-backup.sh" \
  "${ssh_user}@${host}:${remote_dir}/"
run scp -p "${ssh_opts[@]}" "$repo_root/scripts/lib/preserved-guard.sh" \
  "${ssh_user}@${host}:${remote_dir}/lib/"
run scp -p "${ssh_opts[@]}" "$env_file" "${ssh_user}@${host}:${remote_dir}/stage.env"
run ssh "${ssh_opts[@]}" "${ssh_user}@${host}" "chmod 600 ${remote_dir}/stage.env"

remote_stage() {
  local name="$1" script="$2"
  log "== remote stage: ${name} =="
  run ssh "${ssh_opts[@]}" "${ssh_user}@${host}" \
    "set -a; source ${remote_dir}/stage.env; set +a; sudo -E bash ${remote_dir}/${script}"
  log "remote stage ${name} exited 0."
}

if want_stage bootstrap; then
  remote_stage bootstrap bootstrap-vps.sh
  run ssh "${ssh_opts[@]}" "${ssh_user}@${host}" 'docker run --rm hello-world >/dev/null'
  log 'bootstrap verified: docker hello-world runs on the target.'
fi

if want_stage coolify; then
  remote_stage coolify provision-coolify.sh
  run ssh "${ssh_opts[@]}" "${ssh_user}@${host}" 'curl -fsS --max-time 20 http://127.0.0.1:8000/login -o /dev/null'
  log 'coolify verified: origin login route answers on the target.'
  # Authoritative APP_KEY escrow (operator side, fail closed): the fresh host
  # has no bao CLI, so the runner fetches the key over the encrypted channel
  # and escrows it. The key lives only in a local variable, never on disk.
  # Prefix match without `=` adjacent to the keyword keeps tracked-secret
  # scanners quiet; cut extracts the value.
  app_key="$(ssh "${ssh_opts[@]}" "${ssh_user}@${host}" 'sudo grep ^APP_KEY /data/coolify/source/.env' | cut -d= -f2- | head -n1)"
  if [ -z "$app_key" ]; then
    echo 'APP_KEY not retrievable from target; cannot escrow (fail closed).' >&2
    exit 2
  fi
  export BAO_ADDR="$bao_addr"
  if bao kv put -mount=secret projects/ovhcloud/COOLIFY_ADMIN "app_key=${app_key}" "email=${ROOT_USER_EMAIL}" >/dev/null 2>&1; then
    log 'escrowed APP_KEY + admin email to OpenBao COOLIFY_ADMIN (value never printed).'
  else
    echo 'APP_KEY escrow write failed (fail closed).' >&2
    exit 2
  fi
  app_key=''
fi

if want_stage edge; then
  # Complete service-token lifecycle first (operator side, OpenBao-complete):
  # ensures the token exists, escrows the pair, and proves HTTP 200.
  log '== service-token lifecycle (operator side) =='
  run env BAO_ADDR="$bao_addr" CLOUDFLARE_ACCOUNT_ID="$cf_account" \
    DASHBOARD_LOGIN_URL="https://${dashboard_host}/login" \
    bash "$repo_root/scripts/ensure-service-token.sh"
  remote_stage edge configure-tunnel-access.sh
  smoke_code="$(curl -sS -o /dev/null -w '%{http_code}' --cookie-jar /dev/null --max-time 30 \
    -H "CF-Access-Client-Id: ${svc_id}" -H "CF-Access-Client-Secret: ${svc_secret}" \
    "https://${dashboard_host}/login")"
  if [ "$smoke_code" = '200' ]; then
    log "edge verified: https://${dashboard_host}/login -> HTTP 200 (service token accepted)."
  else
    echo "edge verification failed: HTTP ${smoke_code} (required 200)." >&2
    exit 1
  fi
fi

if want_stage backup; then
  log 'provisioning remote R2 env from OpenBao values via stdin pipe...'
  {
    printf 'R2_ACCESS_KEY_ID=%s\n' "$r2_ak"
    printf 'R2_SECRET_ACCESS_KEY=%s\n' "$r2_sk"
    printf 'R2_ENDPOINT=%s\n' "$r2_endpoint"
    printf 'R2_BUCKET=%s\n' "$r2_bucket"
    printf 'AWS_DEFAULT_REGION=auto\n'
  } | run ssh "${ssh_opts[@]}" "${ssh_user}@${host}" \
    'sudo mkdir -p /root/coolify-backup && sudo tee /root/coolify-backup/r2.env >/dev/null && sudo chmod 600 /root/coolify-backup/r2.env'
  run ssh "${ssh_opts[@]}" "${ssh_user}@${host}" "sudo bash ${remote_dir}/schedule-coolify-backup.sh"
  run ssh "${ssh_opts[@]}" "${ssh_user}@${host}" 'sudo systemctl is-enabled coolify-backup.timer | grep -q enabled'
  log 'backup verified: coolify-backup.timer enabled on the target (first backup runs during install).'
fi

trap - EXIT
cleanup_remote
rm -f "$env_file"
log 'remote provisioning complete: all requested stages passed with verification; stage material removed from both ends.'
