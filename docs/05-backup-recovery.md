# 05. Backups and recovery

Backups on this platform are **automated and proven**, not aspirational.
Two executable procedures own all R2 backup/restore traffic; the Coolify
dashboard has **no S3 destination configured by design** (the `s3_storages`
row was deleted 2026-09-14 after proving zero references — single backup
plane, no persisted R2 copy anywhere; R2 credentials travel memory-only
from OpenBao on every run). Do NOT re-create a Coolify S3 destination:
it would reintroduce an at-rest credential copy for zero coverage gain.

Survival goals:

- a broken deployment/application;
- loss/corruption of the entire VPS.

## Backup layers (implemented)

```text
Layer 0  secrets needed for recovery
         OpenBao escrow (COOLIFY_R2 four-field, COOLIFY_ADMIN_BOOTSTRAP,
         COOLIFY_SSH_*, service token) + APP_KEY

Layer 1  Coolify control-plane database
         -> host timer pg_dump -Fc -> Cloudflare R2 (daily, 14-day retention)

Layer 2  application databases
         -> host timer pg_dump -Fc per DB -> R2 app-databases/ (+ manifest
            with tables/rows counts)

Layer 3  persistent volumes/directories
         -> host timer tar snapshots -> R2 app-volumes/ + app-binds/
            (+ manifest with file counts and full container topology)

Layer 4  whole-VPS safety net
         -> OVH automated backup / optional snapshot
```

The timer is `coolify-backup.timer` (daily 02:00 UTC, Persistent=true) driving
`coolify-backup.service`, whose two `ExecStart` lines run the instance backup
(`/root/coolify-backup/backup-to-r2.sh`) and the workload backup
(`scripts/backup-app-workloads.sh`) through the memory-only wrapper
(`scripts/fetch-r2-env.sh -- <script>`). The only secret file on the host is
the least-privilege OpenBao accessor token (`openbao-token`, 0600,
`coolify-r2-reader` policy). R2 contract (all four escrowed at
`secret/projects/ovhcloud/COOLIFY_R2`): `access_key_id`,
`secret_access_key`, `bucket`, `endpoint` — preflight and fetch fail closed
when any field is absent; see `docs/secret-rotation.md`.

## 1. Recovery secrets

Stored outside the VPS and outside Git (OpenBao):

- `APP_KEY` + admin email (`COOLIFY_ADMIN`), admin password
  (`COOLIFY_ADMIN_BOOTSTRAP`)
- Coolify SSH keys (`COOLIFY_SSH_PRIVATE_KEY` / `COOLIFY_SSH_PUBLIC_KEY`)
- R2 credential (`COOLIFY_R2`, four fields)
- Cloudflare machine service token (`COOLIFY_ACCESS_SERVICE_TOKEN`)
- operator SSH private key (`~/.ssh/ovh_coolify_ed25519`, operator disk)

Coolify's restore requires the original `APP_KEY` to decrypt restored
credentials/private keys.

## 2. Coolify instance backup (automated)

`scripts/schedule-coolify-backup.sh` installs the timer; every run pg_dumps
`coolify-db` (`-Fc`, gzip) to a dated R2 key, verifies via head-object, and
prunes keys older than 14 days. Proof: `scripts/rollback-coolify-backup.sh`
restores the latest dump into a disposable probe database, verifies known
data (users count + admin email), drops the probe, reports `RESTORE_OK`
(fail closed). Live proof 2026-09-14.

Manual dashboard instance backups are unnecessary; the destination row does
not exist and must not be recreated.

## 3. Database backups (automated)

`scripts/backup-app-workloads.sh` discovers every PostgreSQL database in
non-infrastructure containers, dumps each (`-Fc`), records tables/rows per
dump in `app-manifests/<stamp>.json`, retains 14 days. Non-Postgres images
fail the run with an explicit coverage gap (only Postgres has a native
dumper here).

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
the manifest records per-volume file counts plus the full container topology
(image, env with secrets `REDACTED`, ports, networks, labels, mounts,
cmd/entrypoint/workdir/user/restart/healthcheck) for faithful recreation.
Coverage gate fails closed on undeclared binds or non-Postgres stateful
images; platform containers (`coolify*` names, `coollabsio/*` images) are
excluded by design.

Recreation credentials need no operator relay: `scripts/recreate-workload.sh
NAME` resolves the database superuser password from OpenBao (explicit
value, reuse of the escrowed `COOLIFY_WORKLOAD_<NAME>` entry, or fresh
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
- major Coolify change
- risky infrastructure experiment

They are **not** the long-term backup strategy. Only one active snapshot at
a time is permitted, so treat it as a temporary rollback point.

## 7. Restore drill: Coolify control plane — DONE 2026-09-14

Proven via `rollback-coolify-backup.sh` (disposable probe restore +
known-data verification + `RESTORE_OK`), not via dashboard clicks. The
full bare-metal sequence (reinstall matching Coolify version, restore
`APP_KEY`, `pg_restore`, SSH keys) follows the official guide during an
actual recovery:

https://coolify.io/docs/core/backup-and-recovery/instance-restore

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
| Coolify `APP_KEY` | OpenBao `COOLIFY_ADMIN` | after install/change | yes |
| Coolify SSH keys | OpenBao | after key changes | yes |
| Coolify instance DB | R2 (host timer) | daily | yes (`RESTORE_OK` 2026-09-14) |
| Application DBs | R2 `app-databases/` | daily | yes (3 live recreates) |
| Persistent mounts | R2 `app-volumes/`/`app-binds/` | daily | yes (byte-identical) |
| Whole VPS | OVH Automated Backup | daily | yes (API-verified 2026-09-14: `state: enabled`, schedule `14:59:00` UTC, rotation 1; no restore points listed yet) |

## 10. Backup failure is an alert

A failed backup should not be a log entry you discover months later.

Configure Coolify notifications for at least:

- backup failures;
- deployment failures;
- server/container health where useful.

If email/notification delivery itself lives on this VPS, use an external
notification path for infrastructure failures where practical.

Explicitly out of automation scope (operator decision pending): no
notification channel is configured, because delivery needs an operator-
supplied credential the repository must never hold (SMTP password or
Discord/Slack webhook). To finish: dashboard → Notifications → add an
email or webhook channel, then enable backup/deployment/health alerts.
Until then, backup health is checked by reading the timer status
(`systemctl status coolify-backup.timer`) and the nightly R2 keys.

## Done when

- [x] `APP_KEY` exists outside the VPS (OpenBao `COOLIFY_ADMIN`)
- [x] Coolify instance DB is backed up to R2 (nightly timer; `RESTORE_OK`)
- [x] every important database has its own R2 backup (per-DB dumps + manifest)
- [x] every irreplaceable volume/directory is identified and backed up (coverage gate enforces)
- [x] OVH daily Automated Backup is verified (read-only API 2026-09-14:
  `automated-backup get-config` → `state: enabled`, schedule 14:59 UTC;
  re-verify with `ovhcloud vps automated-backup get-config
  vps-1525c977.vps.ovh.net` using the OpenBao `OVH_API` escrow)
- [x] `qemu-guest-agent` is active (live 2026-09-14: `systemctl
  is-active` → `active`, `/dev/virtio-ports/org.qemu.guest_agent.0`
  present)
- [x] one Coolify restore has been tested (probe restore 2026-09-14)
- [x] one real application-data restore has been tested (three, 2026-09-14)

Next: [06. Operations and upgrades](06-operations.md)

## References

- Coolify restore: https://coolify.io/docs/core/backup-and-recovery/instance-restore
- OVH automated VPS backup: https://docs.ovhcloud.com/en/guides/bare-metal-cloud/virtual-private-servers/using-automated-backups-on-a-vps
- OVH VPS snapshots: https://docs.ovhcloud.com/en/guides/bare-metal-cloud/virtual-private-servers/using-snapshots-on-a-vps
- Evidence register: `docs/08-iac-redesign-evidence.md`
- Rotation: `docs/secret-rotation.md` (four-field R2 contract)
