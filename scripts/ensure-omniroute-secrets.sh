#!/usr/bin/env bash
# Ensure OmniRoute application secrets exist in OpenBao (operator side).
#
# Lifecycle for the three OmniRoute recovery/application secrets: read each
# field from secret/projects/nomad/OMNIROUTE; when absent, generate a
# fresh value (openssl) and escrow it; when present, reuse untouched (never
# regenerate silently). Values are never printed — only field presence and
# the escrow path are logged. Fail closed on any bao/generation error.
# R2 S3 keys remain the single operator-supplied prerequisite; these three
# are DERIVED (generated + escrowed by automation, never dashboard-minted).
#
# Usage: [BAO_ADDR=...] bash scripts/ensure-omniroute-secrets.sh [--resolve-only]
# --resolve-only proves generation-vs-reuse decisions (field names only) and
# exits before writing; it exists for hermetic testing.
set -euo pipefail

resolve_only=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --resolve-only) resolve_only=1; shift ;;
    -h|--help) echo 'usage: ensure-omniroute-secrets.sh [--resolve-only]'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
command -v bao >/dev/null 2>&1 || { echo 'bao CLI is required.' >&2; exit 2; }
command -v openssl >/dev/null 2>&1 || { echo 'openssl is required to generate secrets.' >&2; exit 2; }
export BAO_ADDR="${BAO_ADDR:-https://secrets.pkubelka.cz}"
entry='secret/projects/nomad/OMNIROUTE'
decisions=()
created=0
for field in STORAGE_ENCRYPTION_KEY API_KEY_SECRET JWT_SECRET; do
  if existing="$(bao kv get -field="$field" "$entry" 2>/dev/null || true)"; [ -n "$existing" ]; then
    decisions+=("${field}=reused"); existing=''
  elif [ "$resolve_only" -eq 1 ]; then
    decisions+=("${field}=would-generate")
  else
    # kv patch (merge) with the value on stdin: sibling fields are never
    # clobbered (plain kv put replaces the whole entry — verified), and
    # the value never appears in argv (ps-visible) or on disk. Patch
    # cannot CREATE an entry (404), so the first field goes via stdin
    # put (atomic create), the rest via patch.
    fresh="$(openssl rand -base64 48)" || { echo "generation failed for ${field} (fail closed)." >&2; exit 2; }
    if [ "$created" -eq 0 ] && ! bao kv get "$entry" >/dev/null 2>&1; then
      printf '%s' "$fresh" | bao kv put -mount=secret projects/nomad/OMNIROUTE "${field}=-" >/dev/null \
        || { echo "escrow create failed for ${field} (fail closed)." >&2; exit 2; }
      created=1
    else
      printf '%s' "$fresh" | bao kv patch -mount=secret projects/nomad/OMNIROUTE "${field}=-" >/dev/null \
        || { echo "escrow failed for ${field} (fail closed)." >&2; exit 2; }
    fi
    fresh=''
    decisions+=("${field}=generated+escrowed")
  fi
done
printf 'omniroute secrets: %s at %s (values never printed).\n' "${decisions[*]}" "$entry"
