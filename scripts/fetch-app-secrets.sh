#!/usr/bin/env bash
# Resolve escrowed application secrets for a backup stamp (operator side).
#
# Reads the app manifest from R2, collects every env_escrowed {var: {path,
# field}} entry, fetches each value from OpenBao, and EITHER prints
# `export VAR='...'` lines (--exports, single-quote escaped like the
# Terraform loader), prints a base64 blob of them (--blob, for stdin-piped
# SSH delivery that mirrors the runner channel), or execs a command with
# them in process environment (-- <cmd...>). Values never touch disk and
# are never logged; only var names + entry paths are.
#
# Usage: [BAO_ADDR=...] bash scripts/fetch-app-secrets.sh --stamp STAMP (--exports | --blob | -- <cmd> [args...])
set -euo pipefail

stamp=''
mode=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --stamp) stamp="$2"; shift 2 ;;
    --stamp=*) stamp="${1#--stamp=}"; shift ;;
    --exports) mode='exports'; shift ;;
    --blob) mode='blob'; shift ;;
    --resolve-latest-stamp) mode='latest'; shift ;;
    --) mode='exec'; shift; break ;;
    -h|--help) echo 'usage: fetch-app-secrets.sh --stamp STAMP (--exports | --blob | -- <cmd> [args...])'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$mode" ] || { echo 'one of --exports, --blob, --resolve-latest-stamp, or -- <cmd> is required.' >&2; exit 2; }
if [ "$mode" != 'latest' ] && [ -z "$stamp" ]; then echo '--stamp is required.' >&2; exit 2; fi
command -v bao >/dev/null 2>&1 || { echo 'bao CLI is required.' >&2; exit 2; }
command -v aws >/dev/null 2>&1 || { echo 'awscli is required.' >&2; exit 2; }
export BAO_ADDR="${BAO_ADDR:-https://secrets.pkubelka.cz}"
AWS_ACCESS_KEY_ID="$(bao kv get -field=access_key_id secret/projects/ovhcloud/COOLIFY_R2 2>/dev/null || true)"
export AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY="$(bao kv get -field=secret_access_key secret/projects/ovhcloud/COOLIFY_R2 2>/dev/null || true)"
export AWS_SECRET_ACCESS_KEY
r2_ep="$(bao kv get -field=endpoint secret/projects/ovhcloud/COOLIFY_R2 2>/dev/null || true)"
export AWS_DEFAULT_REGION=auto
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ] || [ -z "$r2_ep" ]; then
  echo 'COOLIFY_R2 escrow incomplete (fail closed).' >&2; exit 2
fi
if [ "$mode" = 'latest' ]; then
  AWS_DEFAULT_REGION=auto aws --endpoint-url "$r2_ep" s3 ls 's3://ovh-coolify-backups/app-manifests/' 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]{8}T[0-9]{6}Z' | sort | tail -n1
  exit 0
fi
manifest="$(mktemp /tmp/app-secrets-manifest.XXXXXX.json)"
trap 'rm -f "$manifest"' EXIT
AWS_DEFAULT_REGION=auto aws --endpoint-url "$r2_ep" s3api get-object --bucket ovh-coolify-backups --key "app-manifests/${stamp}.json" "$manifest" >/dev/null 2>&1 \
  || { echo "manifest ${stamp} not retrievable from R2 (fail closed)." >&2; exit 2; }
# Build TAB-delimited var/path/field triples (values never touch this layer;
# TAB is safe: var names, entry paths, and field names never contain tabs).
triples=()
while IFS= read -r triple; do
  [ -n "$triple" ] || continue
  triples+=("$triple")
done < <(python3 - "$manifest" <<'PYEOF'
import json,sys
m = json.load(open(sys.argv[1]))
seen = set()
for t in m.get("topology", m.get("containers", [])):
    for var, ref in (t.get("env_escrowed") or {}).items():
        key = (var, ref.get("path"), ref.get("field"))
        if key not in seen and all(key):
            seen.add(key)
            print(var + "\t" + ref["path"] + "\t" + ref["field"])
PYEOF
)
exports=()
for triple in ${triples[@]+"${triples[@]}"}; do
  var="${triple%%$'\t'*}"; rest="${triple#*$'\t'}"; path="${rest%%$'\t'*}"; field="${rest#*$'\t'}"
  val="$(bao kv get -field="$field" "$path" 2>/dev/null || true)"
  [ -n "$val" ] || { echo "escrowed secret ${var} missing at ${path} (fail closed; re-run ensure for its app)." >&2; exit 2; }
  exports+=("export ${var}=$(printf '%s' "$val" | sed "s/'/'\\\\''/g; s/^/'/; s/$/'/")")
  val=''
done
printf '%s\n' "resolved ${#exports[@]} escrowed secret(s) for stamp ${stamp} (names only below)." >&2
for e in ${exports[@]+"${exports[@]}"}; do printf '%s\n' "${e%%=*}" >&2; done
case "$mode" in
  exports) printf '%s\n' ${exports[@]+"${exports[@]}"} ;;
  blob) printf '%s\n' ${exports[@]+"${exports[@]}"} | base64 ;;
  exec) [ "$#" -gt 0 ] || { echo 'no command to exec.' >&2; exit 2; }
    # Capture-then-eval discipline (see the rehearsal bare-eval gate):
    # build the text first so a failure cannot silently eval empty.
    eval_text="$(printf '%s\n' ${exports[@]+"${exports[@]}"})" || exit 2
    eval "$eval_text"
    exec "$@" ;;
esac
