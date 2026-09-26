# shellcheck shell=bash
# Size-safe S3/R2 upload transport (single-PUT fast path + multipart for
# large payloads). Sourced by scripts/backup-app-workloads.sh; never executed
# directly (running it prints usage).
#
# Why this exists: staged database/volume/bind payloads were uploaded with a
# single `s3api put-object`, which fails closed-vacuously on large payloads
# (`EntityTooLarge`/`PutObject` fleet failure, 2026-09-20). Payloads at or
# above S3_MULTIPART_THRESHOLD_BYTES stream through a bounded multipart
# upload instead. Small payloads (manifests, gaps markers) keep the single
# PUT path so small-object behaviour is unchanged.
#
# Bounds (all overridable via environment for fixtures, never via argv):
# - S3_MULTIPART_THRESHOLD_BYTES (default 104857600 = 100 MiB): at or above
#   this local size the multipart path is selected. Pure size comparison —
#   no giant fixture is ever allocated to prove selection.
# - S3_MULTIPART_PART_BYTES (default 33554432 = 32 MiB): one part is staged
#   at a time; peak extra disk is one part, peak memory is the aws CLI's own
#   streaming read (never the whole file).
# - S3_PART_MAX_ATTEMPTS (default 5): per-part bounded retries with linear
#   backoff (attempt N sleeps N*S3_PART_RETRY_BASE_SECONDS, default 2s).
#   create/complete calls retry twice; exhaustion aborts the upload and
#   reports failed/incomplete — never silent green.
# - Temporary files live ONLY under the caller-provided S3MP_TMPDIR (the
#   backup workdir); one part file at a time, removed after each part, with
#   a caller-owned trap for the directory itself.
# - Progress is durable: every stage/byte event appends one JSON line to the
#   caller-provided progress file, plus a background heartbeat at
#   S3_PROGRESS_HEARTBEAT_SECONDS (default 15s, always <=30s) while a part
#   is in flight, so a stalled transfer is observable, never silent.
#
# Verification: after single PUT or complete-multipart, head-object
# ContentLength must equal the local byte count or the upload FAILS (the
# caller must not record the object). Content hashing (sha256) is computed
# by the caller over the staged file and stored in the manifest; the
# rollback plane re-verifies bytes+hash on download. This transport proves
# BYTES MOVED, nothing more.
#
# Explicit non-claim: multipart transport alone does NOT make a live
# SQLite/WAL tar coherent. A hot SQLite directory copied by tar may restore
# unreadable or torn; database coherence needs its own snapshot contract
# (e.g. sqlite3 .backup / VACUUM INTO before staging) before admission.
# This library moves staged bytes reliably; it never asserts they form a
# consistent database.
#
# Credentials: none handled here. Callers export AWS_* memory-only (via
# fetch-r2-env.sh). Nothing in this file prints credential material; the
# aws stub surface used by fixtures carries names/sizes only.
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  echo 's3-multipart.sh is a library: source it, do not execute it.' >&2
  exit 2
fi

S3_MULTIPART_THRESHOLD_BYTES="${S3_MULTIPART_THRESHOLD_BYTES:-104857600}"
S3_MULTIPART_PART_BYTES="${S3_MULTIPART_PART_BYTES:-33554432}"
S3_PART_MAX_ATTEMPTS="${S3_PART_MAX_ATTEMPTS:-5}"
S3_PART_RETRY_BASE_SECONDS="${S3_PART_RETRY_BASE_SECONDS:-2}"
S3_PROGRESS_HEARTBEAT_SECONDS="${S3_PROGRESS_HEARTBEAT_SECONDS:-15}"

_s3mp_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# _s3mp_file_size PATH -> bytes on stdout. Uses stat (GNU/BSD) with a
# bounded wc fallback; never loads the file.
_s3mp_file_size() {
  local path="$1" n
  n="$(stat -c%s "$path" 2>/dev/null || stat -f%z "$path" 2>/dev/null || wc -c <"$path" 2>/dev/null || true)"
  printf '%s' "$n" | tr -d '[:space:]'
}

# s3_upload_method_for_bytes SIZE -> "single" or "multipart" on stdout.
# Pure function of the byte count: fixtures prove threshold selection with
# synthetic sizes and allocate nothing.
s3_upload_method_for_bytes() {
  local size="$1"
  if [ "$size" -ge "$S3_MULTIPART_THRESHOLD_BYTES" ]; then
    printf 'multipart\n'
  else
    printf 'single\n'
  fi
}

# s3_upload_method_for_file PATH -> "single" or "multipart"; fails closed
# when the size cannot be determined.
s3_upload_method_for_file() {
  local size
  size="$(_s3mp_file_size "$1")"
  if [ -z "$size" ] || ! printf '%s' "$size" | grep -qE '^[0-9]+$'; then
    echo "cannot determine size of $1 (fail closed)." >&2
    return 2
  fi
  s3_upload_method_for_bytes "$size"
}

# _s3mp_progress PROGRESS_FILE JSON_FIELDS... — append one durable event.
_s3mp_progress() {
  local progress_file="$1"
  shift
  printf '{"utc":"%s",%s}\n' "$(_s3mp_utc)" "$*" >>"$progress_file"
}

# Heartbeat writer: appends in-progress lines every HEARTBEAT seconds until
# killed. Started per part-upload, stopped right after.
_s3mp_heartbeat_start() {
  local progress_file="$1" key="$2" done_bytes="$3" total_bytes="$4" part="$5"
  # Detached fds: the loop must not inherit the caller's stdout pipe
  # (notably when started inside $(...): an open pipe descriptor would
  # hang the substitution forever waiting for EOF). Events go to the
  # progress file; everything else to /dev/null.
  (
    while sleep "$S3_PROGRESS_HEARTBEAT_SECONDS"; do
      printf '{"utc":"%s","stage":"part-upload","status":"in-progress","key":"%s","part":%s,"bytes_done":%s,"bytes_total":%s}\n' \
        "$(_s3mp_utc)" "$key" "$part" "$done_bytes" "$total_bytes" >>"$progress_file"
    done
  ) </dev/null >/dev/null 2>&1 &
  printf '%s' "$!"
}

_s3mp_heartbeat_stop() {
  local pid="$1"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# _s3mp_retry MAX_ATTEMPTS CMD... — bounded retries with linear backoff.
# Returns the command's status on success, 1 on exhaustion.
_s3mp_retry() {
  local max="$1"
  shift
  local attempt=1
  while [ "$attempt" -le "$max" ]; do
    if "$@"; then
      return 0
    fi
    if [ "$attempt" -ge "$max" ]; then
      return 1
    fi
    sleep $((attempt * S3_PART_RETRY_BASE_SECONDS)) 2>/dev/null || sleep 2
    attempt=$((attempt + 1))
  done
  return 1
}

# s3_verify_remote_size BUCKET KEY EXPECTED_BYTES ENDPOINT — head-object
# ContentLength must equal EXPECTED_BYTES. Prints the remote length.
s3_verify_remote_size() {
  local bucket="$1" key="$2" expected="$3" endpoint="$4" remote
  remote="$(aws --endpoint-url "$endpoint" s3api head-object --bucket "$bucket" --key "$key" --query 'ContentLength' --output text 2>/dev/null || true)"
  remote="$(printf '%s' "$remote" | tr -d '[:space:]')"
  if [ -z "$remote" ] || ! printf '%s' "$remote" | grep -qE '^[0-9]+$'; then
    echo "head-object unreadable for ${key} (fail closed)." >&2
    return 1
  fi
  if [ "$remote" != "$expected" ]; then
    echo "size mismatch for ${key}: local=${expected} remote=${remote} (fail closed)." >&2
    return 1
  fi
  printf '%s' "$remote"
}

# s3_upload_file BUCKET KEY FILE ENDPOINT PROGRESS_FILE
# Uploads FILE with the size-selected transport, verifies remote size, and
# records durable per-stage progress. Prints the verified byte count.
# Tempfiles: one part under S3MP_TMPDIR at a time (caller-owned workdir).
s3_upload_file() {
  local bucket="$1" key="$2" file="$3" endpoint="$4" progress_file="$5" method size hb
  if [ -z "${S3MP_TMPDIR:-}" ] || [ ! -d "$S3MP_TMPDIR" ]; then
    echo 'S3MP_TMPDIR must be an existing caller workdir (restricted tempfiles).' >&2
    return 2
  fi
  if [ ! -f "$file" ]; then
    echo "payload missing: ${file} (fail closed)." >&2
    return 2
  fi
  size="$(_s3mp_file_size "$file")"
  if [ -z "$size" ] || ! printf '%s' "$size" | grep -qE '^[0-9]+$'; then
    echo "cannot determine size of ${file} (fail closed)." >&2
    return 2
  fi
  method="$(s3_upload_method_for_bytes "$size")"
  _s3mp_progress "$progress_file" "\"stage\":\"select\",\"status\":\"ok\",\"key\":\"$key\",\"method\":\"$method\",\"bytes_total\":$size"

  if [ "$method" = 'single' ]; then
    _s3mp_progress "$progress_file" "\"stage\":\"put-object\",\"status\":\"started\",\"key\":\"$key\",\"bytes_total\":$size"
    if aws --endpoint-url "$endpoint" s3api put-object --bucket "$bucket" --key "$key" --body "$file" >/dev/null; then
      if s3_verify_remote_size "$bucket" "$key" "$size" "$endpoint" >/dev/null; then
        _s3mp_progress "$progress_file" "\"stage\":\"put-object\",\"status\":\"verified\",\"key\":\"$key\",\"bytes_done\":$size,\"bytes_total\":$size"
        printf '%s' "$size"
        return 0
      fi
    fi
    _s3mp_progress "$progress_file" "\"stage\":\"put-object\",\"status\":\"failed\",\"key\":\"$key\",\"bytes_total\":$size"
    echo "single-PUT upload failed: ${key} (fail closed)." >&2
    return 1
  fi

  _s3mp_multipart_upload "$bucket" "$key" "$file" "$endpoint" "$progress_file" "$size"
}

# Multipart path: create -> per-part dd slice + bounded-retry upload-part
# (heartbeat while in flight) -> complete -> verify. Any exhaustion aborts
# the upload and records failed/incomplete; the caller must not record the
# object and must not write a green manifest for its stamp.
_s3mp_multipart_upload() {
  local bucket="$1" key="$2" file="$3" endpoint="$4" progress_file="$5" size="$6"
  local upload_id partsize partnum uploaded partfile etags etag hb rc
  partsize="$S3_MULTIPART_PART_BYTES"
  if [ "$partsize" -lt 5242880 ]; then
    partsize=5242880
  fi
  upload_id="$(aws --endpoint-url "$endpoint" s3api create-multipart-upload --bucket "$bucket" --key "$key" --query 'UploadId' --output text 2>/dev/null | tr -d '[:space:]' || true)"
  if [ -z "$upload_id" ] || [ "$upload_id" = 'None' ]; then
    _s3mp_progress "$progress_file" "\"stage\":\"create-multipart\",\"status\":\"failed\",\"key\":\"$key\",\"bytes_total\":$size"
    echo "create-multipart-upload failed: ${key} (fail closed)." >&2
    return 1
  fi
  _s3mp_progress "$progress_file" "\"stage\":\"create-multipart\",\"status\":\"ok\",\"key\":\"$key\",\"bytes_total\":$size"
  partnum=1
  uploaded=0
  etags=''
  partfile="${S3MP_TMPDIR}/s3mp-part.tmp"
  while [ "$uploaded" -lt "$size" ]; do
    rm -f "$partfile"
    if ! dd if="$file" of="$partfile" bs="$partsize" count=1 skip=$((partnum - 1)) status=none 2>/dev/null; then
      _s3mp_progress "$progress_file" "\"stage\":\"slice-part\",\"status\":\"failed\",\"key\":\"$key\",\"part\":$partnum"
      aws --endpoint-url "$endpoint" s3api abort-multipart-upload --bucket "$bucket" --key "$key" --upload-id "$upload_id" >/dev/null 2>&1 || true
      _s3mp_progress "$progress_file" "\"stage\":\"multipart\",\"status\":\"aborted\",\"key\":\"$key\",\"bytes_done\":$uploaded,\"bytes_total\":$size"
      echo "part slice failed: ${key} part ${partnum} (aborted)." >&2
      return 1
    fi
    export S3MP_CURRENT_PART="$partfile" S3MP_CURRENT_PARTNUM="$partnum"
    _s3mp_progress "$progress_file" "\"stage\":\"part-upload\",\"status\":\"started\",\"key\":\"$key\",\"part\":$partnum,\"bytes_done\":$uploaded,\"bytes_total\":$size"
    hb="$(_s3mp_heartbeat_start "$progress_file" "$key" "$uploaded" "$size" "$partnum")"
    if _s3mp_retry "$S3_PART_MAX_ATTEMPTS" _s3mp_upload_one_part "$endpoint" "$bucket" "$key" "$upload_id" "$partnum"; then
      rc=0
    else
      rc=1
    fi
    _s3mp_heartbeat_stop "$hb"
    unset S3MP_CURRENT_PART S3MP_CURRENT_PARTNUM
    if [ "$rc" -ne 0 ]; then
      rm -f "$partfile"
      if aws --endpoint-url "$endpoint" s3api abort-multipart-upload --bucket "$bucket" --key "$key" --upload-id "$upload_id" >/dev/null 2>&1; then
        _s3mp_progress "$progress_file" "\"stage\":\"multipart\",\"status\":\"aborted\",\"key\":\"$key\",\"part\":$partnum,\"bytes_done\":$uploaded,\"bytes_total\":$size"
        echo "part ${partnum} exhausted retries: ${key} (aborted, fail closed)." >&2
      else
        _s3mp_progress "$progress_file" "\"stage\":\"multipart\",\"status\":\"incomplete\",\"key\":\"$key\",\"part\":$partnum,\"bytes_done\":$uploaded,\"bytes_total\":$size"
        echo "part ${partnum} exhausted retries AND abort failed: ${key} (INCOMPLETE upload, needs operator cleanup)." >&2
      fi
      return 1
    fi
    etag="$(tr -d '[:space:]\"' < "${S3MP_TMPDIR}/s3mp-etag.tmp" 2>/dev/null || true)"
    rm -f "$partfile" "${S3MP_TMPDIR}/s3mp-etag.tmp"
    if [ -z "$etag" ]; then
      aws --endpoint-url "$endpoint" s3api abort-multipart-upload --bucket "$bucket" --key "$key" --upload-id "$upload_id" >/dev/null 2>&1 || true
      _s3mp_progress "$progress_file" "\"stage\":\"multipart\",\"status\":\"aborted\",\"key\":\"$key\",\"part\":$partnum,\"bytes_done\":$uploaded,\"bytes_total\":$size"
      echo "missing ETag for ${key} part ${partnum} (aborted, fail closed)." >&2
      return 1
    fi
    if [ -z "$etags" ]; then
      etags="{\"ETag\":\"$etag\",\"PartNumber\":$partnum}"
    else
      etags="$etags,{\"ETag\":\"$etag\",\"PartNumber\":$partnum}"
    fi
    uploaded=$((uploaded + partsize))
    if [ "$uploaded" -gt "$size" ]; then
      uploaded="$size"
    fi
    _s3mp_progress "$progress_file" "\"stage\":\"part-upload\",\"status\":\"verified\",\"key\":\"$key\",\"part\":$partnum,\"bytes_done\":$uploaded,\"bytes_total\":$size"
    partnum=$((partnum + 1))
  done
  printf '{"Parts":[%s]}' "$etags" >"${S3MP_TMPDIR}/s3mp-complete.json"
  if ! _s3mp_retry 2 aws --endpoint-url "$endpoint" s3api complete-multipart-upload --bucket "$bucket" --key "$key" --upload-id "$upload_id" --multipart-upload "file://${S3MP_TMPDIR}/s3mp-complete.json" >/dev/null; then
    rm -f "${S3MP_TMPDIR}/s3mp-complete.json"
    _s3mp_progress "$progress_file" "\"stage\":\"complete-multipart\",\"status\":\"incomplete\",\"key\":\"$key\",\"bytes_done\":$uploaded,\"bytes_total\":$size"
    echo "complete-multipart-upload failed: ${key} (INCOMPLETE, needs operator cleanup)." >&2
    return 1
  fi
  rm -f "${S3MP_TMPDIR}/s3mp-complete.json"
  if s3_verify_remote_size "$bucket" "$key" "$size" "$endpoint" >/dev/null; then
    _s3mp_progress "$progress_file" "\"stage\":\"multipart\",\"status\":\"verified\",\"key\":\"$key\",\"parts\":$((partnum - 1)),\"bytes_done\":$size,\"bytes_total\":$size"
    printf '%s' "$size"
    return 0
  fi
  _s3mp_progress "$progress_file" "\"stage\":\"multipart\",\"status\":\"failed\",\"key\":\"$key\",\"bytes_done\":$uploaded,\"bytes_total\":$size"
  echo "multipart size verification failed: ${key} (fail closed)." >&2
  return 1
}

# Single-part uploader used under _s3mp_retry. Reads the slice path from
# S3MP_CURRENT_PART (retry re-reads the same staged slice; nothing is
# re-sliced between attempts). ETag lands in s3mp-etag.tmp.
_s3mp_upload_one_part() {
  local endpoint="$1" bucket="$2" key="$3" upload_id="$4" partnum="$5"
  aws --endpoint-url "$endpoint" s3api upload-part --bucket "$bucket" --key "$key" --upload-id "$upload_id" --part-number "$partnum" --body "$S3MP_CURRENT_PART" --query 'ETag' --output text >"${S3MP_TMPDIR}/s3mp-etag.tmp" 2>/dev/null
}

# s3_verify_downloaded FILE EXPECTED_SHA256 EXPECTED_BYTES — size then
# sha256 equality for a downloaded payload against its manifest record.
# Same code on the rollback plane and in fixtures: a corrupt/truncated
# download fails closed here, never as a silent short restore. Legacy
# entries carry no sha256 (empty string): the caller logs LEGACY and
# proves restorability only — new manifests must always record both.
s3_verify_downloaded() {
  local file="$1" expected_sha="$2" expected_bytes="$3" actual_bytes actual_sha
  if [ ! -f "$file" ]; then
    echo "downloaded payload missing: ${file} (fail closed)." >&2
    return 1
  fi
  actual_bytes="$(_s3mp_file_size "$file")"
  if [ "$actual_bytes" != "$expected_bytes" ]; then
    echo "size mismatch for ${file}: manifest=${expected_bytes} downloaded=${actual_bytes} (fail closed)." >&2
    return 1
  fi
  if [ -z "$expected_sha" ]; then
    return 0
  fi
  actual_sha="$(sha256sum "$file" 2>/dev/null | awk '{print $1}' || true)"
  if [ "$actual_sha" != "$expected_sha" ]; then
    echo "sha256 mismatch for ${file} (fail closed; expected record differs from downloaded bytes)." >&2
    return 1
  fi
  return 0
}

# manifest_entries_complete MANIFEST_JSON — every database/volume/bind entry
# must carry a non-empty key, a 64-hex sha256, and a non-negative integer
# byte count; containers must carry name+image. Prints "complete" or
# "incomplete: <reason>" and returns nonzero when incomplete. Used by the
# backup plane (refuse green manifest) and the rollback plane (refuse to
# certify an incomplete manifest). Transport bytes-moved proof only: this
# says nothing about database coherence (see header).
manifest_entries_complete() {
  python3 - "$1" <<'MANIFEST_PY'
import json, re, sys
try:
    m = json.load(open(sys.argv[1]))
except (OSError, ValueError) as e:
    print("incomplete: manifest unreadable (%s)" % e)
    raise SystemExit(1)
problems = []
for section in ("databases", "volumes", "binds"):
    entries = m.get(section, [])
    if not isinstance(entries, list):
        problems.append("%s not a list" % section)
        continue
    for i, e in enumerate(entries):
        tag = "%s[%d]" % (section, i)
        if not isinstance(e, dict) or not e.get("key"):
            problems.append("%s missing key" % tag)
            continue
        if not re.fullmatch(r"[0-9a-f]{64}", str(e.get("sha256", ""))):
            problems.append("%s missing sha256" % tag)
        b = e.get("bytes", None)
        if not isinstance(b, int) or isinstance(b, bool) or b < 0:
            problems.append("%s missing bytes" % tag)
containers = m.get("containers", [])
if not isinstance(containers, list):
    problems.append("containers not a list")
else:
    for i, c in enumerate(containers):
        if not isinstance(c, dict) or not c.get("name") or not c.get("image"):
            problems.append("containers[%d] missing name/image" % i)
if problems:
    print("incomplete: %s" % "; ".join(problems[:8]))
    raise SystemExit(1)
print("complete")
MANIFEST_PY
}

# manifest_classify MANIFEST_JSON — "complete" (all payload entries carry
# key+sha256+bytes), "legacy" (no payload entry carries transport
# records: pre-multipart manifests, verified by restorability only), or
# "incomplete: <reason>" (unreadable, missing keys, or mixed
# generations — a partially upgraded manifest is tampered-or-torn until
# proven otherwise). Rollback refuses incomplete; backup refuses green.
manifest_classify() {
  python3 - "$1" <<'CLASSIFY_PY'
import json, re, sys
try:
    m = json.load(open(sys.argv[1]))
except (OSError, ValueError) as e:
    print("incomplete: manifest unreadable (%s)" % e)
    raise SystemExit(1)
problems, new_count, old_count = [], 0, 0
for section in ("databases", "volumes", "binds"):
    entries = m.get(section, [])
    if not isinstance(entries, list):
        problems.append("%s not a list" % section)
        continue
    for i, e in enumerate(entries):
        tag = "%s[%d]" % (section, i)
        if not isinstance(e, dict) or not e.get("key"):
            problems.append("%s missing key" % tag)
            continue
        has_new = bool(e.get("sha256")) or e.get("bytes") is not None
        if has_new:
            new_count += 1
            if not re.fullmatch(r"[0-9a-f]{64}", str(e.get("sha256", ""))):
                problems.append("%s missing sha256" % tag)
            b = e.get("bytes", None)
            if not isinstance(b, int) or isinstance(b, bool) or b < 0:
                problems.append("%s missing bytes" % tag)
        else:
            old_count += 1
containers = m.get("containers", [])
if not isinstance(containers, list):
    problems.append("containers not a list")
else:
    for i, c in enumerate(containers):
        if not isinstance(c, dict) or not c.get("name") or not c.get("image"):
            problems.append("containers[%d] missing name/image" % i)
if problems:
    print("incomplete: %s" % "; ".join(problems[:8]))
    raise SystemExit(1)
if new_count and old_count:
    print("incomplete: mixed transport generations (%d new, %d legacy entries)" % (new_count, old_count))
    raise SystemExit(1)
print("complete" if new_count else "legacy")
CLASSIFY_PY
}
