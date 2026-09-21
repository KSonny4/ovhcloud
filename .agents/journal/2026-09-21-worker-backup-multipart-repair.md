# Multipart backup repair — worker journal

- Issue: KSonny4/ovhcloud#5; lane `.worktrees/nomad-backup-repair-5`, branch
  `fix/app-backup-multipart-5`, base `c6a680e` (reviewed baseline).
- Role: implementation worker; no host apply, no new paid storage, no prod
  removal, no whole-backup rerun, no primary-branch mutation, no
  merge/deploy/close, no nested agents, no credentials read or printed.
- Failing stage revalidated from receipts, not reproduction: 2026-09-20
  fleet research `EntityTooLarge`/`PutObject` on staged app payloads; local
  source used bare `s3api put-object` for db/volume/bind payloads
  (backup-app-workloads.sh). No backup was rerun here.
- Guidance actually loaded: owning `AGENTS.md`, `CONTEXT.md` (head),
  `docs/engineering-guidance.md` (adoption overlay + Nomad divergence),
  retained guidance `/tmp/nomad-platform-review-6/guidance`
  (`AGENTS.md`, `authority/authority.md`, `standards/operations.md`,
  `standards/secrets.md`). Task-called playbooks: outcome-reporting,
  operations, secrets (credential-memory-only + no-value-logging rules
  honored). No Superpowers skill used.

## Changes (this lane only)

1. `scripts/lib/s3-multipart.sh` (new): size-safe transport. Single-PUT
   under `S3_MULTIPART_THRESHOLD_BYTES` (100 MiB), bounded multipart above
   (32 MiB parts, one staged at a time under caller `S3MP_TMPDIR`, 5
   attempts/part linear backoff, abort + aborted/incomplete record on
   exhaustion, create/complete retried x2). Durable JSONL byte/stage
   progress + <=30 s heartbeat (15 s default, structurally asserted).
   Remote-size verification post-upload. `s3_verify_downloaded` (size then
   sha256) shared by rollback + fixtures. `manifest_entries_complete`
   (backup gate) + `manifest_classify` (complete|legacy|incomplete; mixed
   generations refuse). Header states the non-claim: bytes-moved proof
   only, never SQLite/WAL coherence (separate contract).
2. `scripts/backup-app-workloads.sh`: sources the lib (fail closed when
   absent); db/volume/bind uploads go through `s3_upload_file`; manifest
   entries gain `bytes`+`sha256` recorded pre-upload; green manifest only
   when zero failures AND the completeness gate passes, else
   `failed-<stamp>.progress.jsonl` evidence and no green manifest (fixes
   the old unconditional-manifest-on-FAILED path). New
   `--self-test-multipart`: 13 stubbed-`aws` fixture cases (threshold
   selection with a synthetic 5 GB size and no giant allocation, verified
   single-PUT, size-mismatch fail-closed, retried multipart, interrupted
   abort with no complete + no stray part, hash ok/corrupt, good/bad/
   unreadable manifests, heartbeat cadence bound). Fixture caught a real
   hang first run: heartbeat subshell inherited the `$(...)` stdout pipe;
   fixed with detached fds (`</dev/null >/dev/null 2>&1`).
3. `scripts/rollback-app-workloads.sh`: sources the lib; probe + recreate
   planes download the stamp manifest (missing manifest now fails closed),
   classify it (legacy = restorability-only with per-entry LEGACY log;
   incomplete/mixed refuse), and verify every download's bytes+sha256 via
   `verify_manifest_file`. Latest-manifest selector now excludes
   `failed-` evidence keys.
4. `scripts/schedule-host-backup.sh`: installs `lib/s3-multipart.sh` to
   `${backup_dir}/lib/` beside the companion (fail closed when found
   nowhere); `scripts/validate-repository.sh`: new lib in `bash -n` +
   shellcheck lists.
5. `docs/05-backup-recovery.md`: transport contract documented in §3
   (thresholds, bounds, progress, gate, legacy/mixed handling, fixture
   entrypoint, SQLite non-claim). `CONTEXT.md` untouched: invariant 5
   (restore proves backups) already owns the principle; detail lives in
   the §5 runbook doc.

## Proof

- `bash scripts/backup-app-workloads.sh --self-test-multipart`: 13/13
  PASS (no network, no credentials, no daemon).
- Existing self-tests unchanged green: `--self-test-topology`,
  `--self-test-db-flags`, `--self-test-escrow`.
- `shellcheck` clean on all five touched/added shell files.
- `manifest_classify` probed directly: legacy → `legacy`, new → `complete`,
  mixed → `incomplete` (rc=1).
- Owning repo gate `validate-repository.sh` bounded run + `git diff --check`
  (see result file).

## Residual

- Nomad-snapshot path (`schedule-host-backup.sh` embedded script) still
  single-PUTs; snapshots are small and out of this issue's app-payload
  scope — noted, not changed.
- No live R2/host proof (forbidden in this lane); transport proven by
  fixtures + static gates only. Guarded rollout from merged source still
  required. Restore rehearsal with RPO/RTO measurement is a separate slice.
