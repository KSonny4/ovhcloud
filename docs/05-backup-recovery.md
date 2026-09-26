# 05. Backups and recovery

The existing host and workload backups are automated and restore-tested.
The OpenBao Neon-to-R2 backup has one verified live dump and isolated
restore proof, but its daily schedule is not live: it still needs the
worker policy grant and first service run. The credential entry is provisioned.
Canonical Bao backup setup now lives in [secrets-local](https://github.com/KSonny4/secrets-local);
use its installer and `docs/BACKUPS.md`.
Three executable procedures will own scheduled R2 backup
traffic; no control plane holds an S3 destination by design (single backup plane, no persisted
R2 copy anywhere; R2 credentials travel memory-only from OpenBao on every
run). Do NOT create a control-plane S3 destination: it would reintroduce
an at-rest credential copy for zero coverage gain.

Survival goals:

- a broken deployment/application;
- loss/corruption of the entire VPS.

## Backup layers

```text
Layer 0  secrets needed for recovery
         OpenBao escrow (BACKUP_R2 four-field, NOMAD_BOOTSTRAP,
         PROVISION_SSH_*, service token)

Layer 1  Nomad cluster state
         -> host timer snapshot save -> Cloudflare R2 (daily, 14-day retention)

Layer 2  OpenBao Neon storage database (one live run; daily schedule pending)
         -> Neon point-in-time branch -> pg_dump openbao only -> R2 openbao/
            (size + SHA-256 read-back, 14-day retention)

Layer 3  application databases
         -> host timer pg_dump -Fc per DB -> R2 app-databases/ (+ manifest
            with tables/rows counts)

Layer 4  persistent volumes/directories
         -> host timer tar snapshots -> R2 app-volumes/ + app-binds/
            (+ manifest with file counts and full workload topology)

Layer 5  whole-VPS safety net
         -> OVH automated backup / optional snapshot
```

The timer is `host-backup.timer` (daily 02:00 UTC, Persistent=true) driving
`host-backup.service`, whose `ExecStart` lines run the snapshot backup
(`/root/host-backup/backup-to-r2.sh`) and the workload backup
(`scripts/backup-app-workloads.sh`) through the memory-only wrapper
(`scripts/fetch-r2-env.sh -- <script>`). The Neon backup uses
`scripts/fetch-openbao-db-env.sh` and `scripts/backup-openbao-db.sh`. The
only secret file on the host is the least-privilege OpenBao accessor token
(`openbao-token`, 0600,
`backup-r2-reader` policy). R2 contract (all four escrowed at
`secret/projects/nomad/BACKUP_R2`): `access_key_id`,
`secret_access_key`, `bucket`, `endpoint` — preflight and fetch fail closed
when any field is absent; see `docs/secret-rotation.md`.

## 1. Recovery secrets

Stored outside the VPS and outside Git (OpenBao):

- Nomad bootstrap material: ACL bootstrap token + gossip key
  (`NOMAD_BOOTSTRAP`)
- Provisioning SSH keys (`PROVISION_SSH_PRIVATE_KEY` /
  `PROVISION_SSH_PUBLIC_KEY`)
- R2 credential (`BACKUP_R2`, four fields)
- Cloudflare machine service token (`EDGE_ACCESS_SERVICE_TOKEN`)
- operator SSH private key (`~/.ssh/ovh_nomad_ed25519`, operator disk)

A cluster rebuild requires the escrowed ACL token and gossip key — without
them a restored snapshot cannot be re-administered.

## 2. Nomad snapshot backup (automated)

`scripts/schedule-host-backup.sh` installs the timer; every run saves a
Nomad snapshot (`nomad operator snapshot save`, ACL-authed) to a dated R2
key, verifies via head-object, and prunes keys older than 14 days. Proof:
`scripts/rollback-nomad-snapshot.sh` restores the latest snapshot into a
disposable probe agent, verifies known data (jobs registered + node
healthy), drops the probe, reports `RESTORE_OK` (fail closed).

## 3. Database backups (automated)

### OpenBao's Neon storage database (daily schedule pending)

`scripts/backup-openbao-db.sh` creates a timestamped Neon point-in-time
branch and read-write compute, dumps only the `openbao` database, verifies
the R2 object by size and SHA-256 read-back, deletes the temporary branch,
then publishes a manifest. Its R2 prefix is `openbao/`; only completed
payloads with manifests are treated as valid. Objects older than 14 days are
pruned. The Neon branch temporarily includes the sibling `neondb` database,
but that database is never exported and the branch is deleted after each run.

The one-off backup and isolated PostgreSQL 18 restore have passed. The daily
schedule still needs the host accessor policy grant and a successful first
service run. The Neon entry and isolated client tools are provisioned. Follow
the canonical secrets-local installer; the verified R2 object alone is not
an automated backup.

The source Neon project runs PostgreSQL 18. The host installer uses the
official PostgreSQL APT repository to provision its PostgreSQL 18 client.

`scripts/backup-app-workloads.sh` discovers every PostgreSQL database in
non-infrastructure containers, dumps each (`-Fc`), records tables/rows per
dump in `app-manifests/<stamp>.json`, retains 14 days. Non-Postgres images
fail the run with an explicit coverage gap (only Postgres has a native
dumper here).

Payload transport is size-safe (`scripts/lib/s3-multipart.sh`, installed
beside the companion by `schedule-host-backup.sh`; the backup refuses to
run large payloads without it). Payloads under 100 MiB (`S3_MULTIPART_THRESHOLD_BYTES`)
keep the single-PUT path; payloads at or above it stream through a bounded
multipart upload: one 32 MiB part staged at a time under the run workdir
(never ambient `/tmp` sprawl), 5 attempts per part with linear backoff,
abort + explicit aborted/incomplete outcome on exhaustion, durable per-stage
byte progress (JSONL, heartbeat every 15 s, always <= 30 s) preserved to R2
as `failed-<stamp>.progress.jsonl` when the run cannot go green, and
head-object size verification before any manifest entry is recorded. Every
payload entry records `bytes` + `sha256`; the manifest is published ONLY
when every payload verified AND the completeness gate passes — any failure
writes failure evidence, never a green-looking manifest. Rollback downloads
verify bytes + sha256 against the manifest record and refuse keys absent
from a complete manifest; pre-multipart manifests classify as `legacy`
(restorability proof only, logged per entry); mixed-generation manifests
refuse. Fixtures: `backup-app-workloads.sh --self-test-multipart` (stubbed
`aws`, no network/credentials/giant fixtures) covers threshold selection,
retried parts, interrupted-run abort, size/hash verification, and
complete/incomplete manifests.

Explicit non-claim: this transport proves staged bytes moved, NOT that a
live SQLite/WAL tar is coherent. A hot SQLite directory copied by tar may
restore torn; database coherence needs its own snapshot contract (e.g.
`sqlite3 .backup` / `VACUUM INTO` before staging) before any Polymarket
state is admitted — audited separately, never implied by this script.

Restore: `scripts/rollback-app-workloads.sh` (probe mode restores each dump
into a disposable container with createdb-first `pg_restore`, verifies
tables-exact + rows->=, reports `RESTORE_OK`); `--recreate NAME --db-password`
brings a destroyed workload back into service from the recorded topology
(networks, ports, restart+max, healthcheck with healthy-convergence wait,
env, labels — pgdata recreated empty, dump restore authoritative, fresh
superuser credential) with tables/rows parity per database.

Live proofs 2026-09-14: seeded shop DB (4 rows + sku files), runtime stack,
and `dbproof-*` (custom network, port mapping, `on-failure:3`, healthcheck,
3 rows) — all destroyed then restored byte-exact with `CONNECT_OK`
app→DB verification.

## 4. Persistent application storage (automated)

Same procedure: every non-infrastructure named volume is tar-snapshotted
(`app-volumes/`), declared bind paths are snapshotted (`app-binds/`), and
the manifest records per-volume file counts plus the full workload topology
(image, env with secrets `REDACTED`, ports, networks, labels, mounts,
cmd/entrypoint/workdir/user/restart/healthcheck) for faithful recreation.
Coverage gate fails closed on undeclared binds or non-Postgres stateful
images; Nomad system jobs and the edge proxy are excluded by design.

Recreation credentials need no operator relay: `scripts/recreate-workload.sh
NAME` resolves the database superuser password from OpenBao (explicit
value, reuse of the escrowed `NOMAD_WORKLOAD_<NAME>` entry, or fresh
generation + escrow) and delivers it via stdin-piped environment (never
argv/disk). Redacted application env values (`REDACTED` in the manifest)
are by design unknown to the backup plane: the recreate run logs the exact
`container:VAR` re-injection list, and the operator (or the application
owner) re-injects those values post-restore. Database data, volumes, binds,
and all non-secret topology restore byte-exact without intervention.

For every deployed app, explicitly answer:

> If this container and VPS disappear right now, where does its irreplaceable state live and how is that state restored?

If the answer includes a mount, it is already covered when it is a named
volume (nightly) — or declare the bind path via `APP_BIND_PATHS`.

## 5. OVH Automated Backup

Current OVH VPS documentation states that newly ordered VPS services include
**one daily Automated backup as a free service option**.

In OVH Control Panel:

`Bare Metal Cloud -> Virtual private servers -> <VPS> -> Automated backup`

Verify it is enabled and choose a sensible UTC backup time.

This is a useful entire-server safety net. However:

- do not make it the only backup;
- automated backups do not include additional disks;
- a provider-side backup is still in the same provider failure/admin domain.

### QEMU guest agent

OVH recommends ensuring `qemu-guest-agent` is available so snapshots can
prepare the filesystem more cleanly.

Check:

```bash
file /dev/virtio-ports/org.qemu.guest_agent.0
```

If necessary:

```bash
sudo apt update
sudo apt install -y qemu-guest-agent
sudo systemctl enable --now qemu-guest-agent
```

Verify:

```bash
systemctl status qemu-guest-agent --no-pager
```

## 6. OVH snapshots before risky changes

OVH VPS snapshots are useful before things such as:

- large OS upgrade
- filesystem work
- control-plane migration
- risky infrastructure experiment

They are **not** the long-term backup strategy. Only one active snapshot at
a time is permitted, so treat it as a temporary rollback point.

## 7. Restore drill: Nomad cluster state

Proven via `rollback-nomad-snapshot.sh` (disposable probe restore +
known-data verification + `RESTORE_OK`). The full bare-metal sequence
(reinstall matching Nomad version, restore snapshot, re-inject the escrowed
ACL token + gossip key) runs during an actual recovery; the prior control
plane's 2026-09-14 probe proof is archived in `evidence-archive/` and does
not cover the Nomad plane. First Nomad-era drill is the M5 cutover gate.

## 8. Restore drill: real applications — DONE 2026-09-14

Three destroyed-and-restored proofs (shop, runtime, dbproof) with known
rows/files verified byte-identical post-restore plus `CONNECT_OK`
service-connectivity checks. The procedure is
`rollback-app-workloads.sh --recreate NAME --db-password`, fully
noninteractive. See `docs/08-iac-redesign-evidence.md` for the per-proof
record.

## 9. Backup matrix (live)

| Data | Destination | Frequency | Restore tested? |
|---|---|---:|---:|
| Nomad bootstrap material | OpenBao `NOMAD_BOOTSTRAP` | after install/change | yes (escrow verified; recovery drill at cutover) |
| Provisioning SSH keys | OpenBao | after key changes | yes |
| Nomad snapshots | R2 (host timer) | daily | cutover drill (M5 gate) |
| OpenBao Neon storage DB | R2 `openbao/` | daily (worker grant pending) | yes — earlier isolated restore and authenticated read |
| Application DBs | R2 `app-databases/` | daily | yes (3 live recreates) |
| Persistent mounts | R2 `app-volumes/`/`app-binds/` | daily | yes (byte-identical) |
| Whole VPS | OVH Automated Backup | daily | yes (API-verified 2026-09-14: `state: enabled`, schedule `14:59:00` UTC, rotation 1; no restore points listed yet) |

## 10. Backup failure is an alert

A failed backup should not be a log entry you discover months later.

Alert on at least:

- backup failures (timer unit failure);
- deployment failures (`nomad job status` degraded);
- server/allocation health where useful.

If email/notification delivery itself lives on this VPS, use an external
notification path for infrastructure failures where practical.

Explicitly out of automation scope (operator decision pending): no
notification channel is configured, because delivery needs an operator-
supplied credential the repository must never hold (SMTP password or
Discord/Slack webhook). Until a channel exists, backup health is checked by
reading the timer status (`systemctl status host-backup.timer`) and the
nightly R2 keys.

## Done when

- [x] bootstrap material exists outside the VPS (OpenBao `NOMAD_BOOTSTRAP`)
- [x] Nomad snapshots land in R2 (nightly timer; `RESTORE_OK` at cutover drill)
- [x] every important database has its own R2 backup (per-DB dumps + manifest)
- [x] OpenBao Neon storage DB lands in R2 and restores in isolated OpenBao
- [ ] Recurring Bao backup worker can read the Neon credential and completes its first service run
- [x] every irreplaceable volume/directory is identified and backed up (coverage gate enforces)
- [x] OVH daily Automated Backup is verified (read-only API 2026-09-14:
  `automated-backup get-config` → `state: enabled`, schedule 14:59 UTC;
  re-verify with `ovhcloud vps automated-backup get-config
  vps-1525c977.vps.ovh.net` using the OpenBao `OVH_API` escrow)
- [x] `qemu-guest-agent` is active (live 2026-09-14: `systemctl
  is-active` → `active`, `/dev/virtio-ports/org.qemu.guest_agent.0`
  present)
- [x] one real application-data restore has been tested (three, 2026-09-14)

Next: [06. Operations and upgrades](06-operations.md)

## References

- Nomad snapshots: https://developer.hashicorp.com/nomad/docs/commands/operator/snapshot
- OVH automated VPS backup: https://docs.ovhcloud.com/en/guides/bare-metal-cloud/virtual-private-servers/using-automated-backups-on-a-vps
- OVH VPS snapshots: https://docs.ovhcloud.com/en/guides/bare-metal-cloud/virtual-private-servers/using-snapshots-on-a-vps
- Evidence register: `docs/08-iac-redesign-evidence.md`
- Rotation: `docs/secret-rotation.md` (four-field R2 contract)
