# 05. Backups and recovery

Use multiple independent backup layers. The goal is to survive both:

- a broken deployment/application;
- loss/corruption of the entire VPS.

A Coolify instance backup alone is **not enough**. It restores Coolify projects/settings/credentials/deployment history, but not application databases, services or persistent volumes.

## Backup layers

```text
Layer 0  secrets needed for recovery
         APP_KEY + Coolify SSH keys

Layer 1  Coolify control-plane database
         -> Cloudflare R2

Layer 2  application databases
         -> logical database backups -> Cloudflare R2

Layer 3  persistent volumes/directories
         -> storage backups -> Cloudflare R2

Layer 4  whole-VPS safety net
         -> OVH automated backup / optional snapshot
```

## 1. Recovery secrets

Store these outside the VPS and outside Git:

- `APP_KEY` from `/data/coolify/source/.env`
- an encrypted copy of the relevant Coolify environment/secrets if desired
- backup of `/data/coolify/ssh/keys/` when you care about replacing the server without regenerating every managed-server key
- your human SSH private key
- Cloudflare/R2 recovery credentials

Coolify's current restore guide explicitly requires the original `APP_KEY` to decrypt restored credentials/private keys.

## 2. Coolify instance backup

In Coolify, configure recurring self-hosted instance backups to the validated Cloudflare R2 storage.

Suggested baseline:

```text
frequency: daily
remote storage: Cloudflare R2
retention: enough to cover accidental changes for at least 1-2 weeks
```

After the first run, verify the backup exists remotely and is non-zero-sized.

Also record the Coolify version associated with restore tests. The restore flow can require reinstalling the matching version before migrations are applied.

## 3. Database backups

For every stateful database managed by Coolify, configure its own scheduled backup.

Examples:

- PostgreSQL
- MySQL/MariaDB
- MongoDB
- ClickHouse where supported by Coolify

Use Cloudflare R2 as the remote S3 destination.

Suggested baseline for important databases:

```text
frequency: daily, or more often if the data-loss window requires it
retention: 14-30 days
remote copy: required
```

For important/high-write databases, choose the schedule based on the acceptable recovery-point objective rather than copying the example blindly.

After configuring each database, trigger one manual backup and verify it in R2.

## 4. Persistent application storage

Applications often store state outside a database, for example:

- uploaded files
- SQLite files
- generated assets
- service configuration
- application-specific data directories

Coolify can schedule backups for supported volume/directory mounts to S3-compatible storage.

This platform additionally runs an executable host-level procedure
(`scripts/backup-app-workloads.sh`, nightly via `coolify-backup.timer`)
that dumps every application PostgreSQL database and snapshots every
non-infrastructure Docker volume to R2 (`app-databases/`, `app-volumes/`,
`app-manifests/`, 14-day retention) — proven live 2026-09-14 against a
disposable seeded workload (3 known rows + 2 known files destroyed, then
restored byte-identical from R2; see the evidence register). Instance scope
is covered by `scripts/schedule-coolify-backup.sh` + `scripts/rollback-coolify-backup.sh` (RESTORE_OK).

For every deployed app, explicitly answer:

> If this container and VPS disappear right now, where does its irreplaceable state live and how is that state restored?

If the answer includes a mount, back it up.

Important: Coolify's current storage-backup UI creates/downloads archives, but restore may still be a manual process. Test it on a separate path/environment before trusting it.

## 5. OVH Automated Backup

Current OVH VPS documentation states that newly ordered VPS services include **one daily Automated backup as a free service option**.

In OVH Control Panel:

`Bare Metal Cloud -> Virtual private servers -> <VPS> -> Automated backup`

Verify it is enabled and choose a sensible UTC backup time.

This is a useful entire-server safety net and allows either restoration or mounting the backup to retrieve files.

However:

- do not make it the only backup;
- automated backups do not include additional disks;
- a provider-side backup is still in the same provider failure/admin domain.

### QEMU guest agent

OVH recommends ensuring `qemu-guest-agent` is available so snapshots can prepare the filesystem more cleanly.

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

They are **not** the long-term backup strategy. OVH explicitly describes snapshots as a convenience before risky changes rather than a complete backup solution.

Current OVH VPS snapshot behaviour also permits only one active snapshot at a time, so treat it as a temporary rollback point.

## 7. Restore drill: Coolify control plane

Do this at least once before the host becomes important.

Current Coolify restore requirements include:

- a `.dmp` Coolify database backup;
- the original `APP_KEY`;
- SSH access;
- ideally the Coolify version associated with the backup;
- Coolify SSH key material when replacing the host.

High-level restore sequence:

1. Prepare the same or replacement server.
2. Install Coolify so `coolify-db` exists/runs.
3. Copy the `.dmp` backup locally.
4. Stop `coolify`, `coolify-redis` and `coolify-realtime`, leaving `coolify-db` running.
5. Put the **saved original `APP_KEY`** into `/data/coolify/source/.env`. On a replacement install, replace only `APP_KEY`; keep newly generated DB settings that match the new containers.
6. Restore the PostgreSQL dump with `pg_restore` according to the official Coolify restore guide.
7. Restore Coolify SSH keys if replacing the machine.
8. Re-run the Coolify installer, using the matching version if required.
9. Verify dashboard, projects, localhost validation and credentials.
10. Restore each application's database and persistent storage separately.

Follow the official commands during an actual recovery because exact version-specific details may change:

https://coolify.io/docs/core/backup-and-recovery/instance-restore

## 8. Restore drill: one real application

Pick a non-critical app with a database or volume and prove the full path:

1. create known test data;
2. run database/volume backup;
3. deploy a second disposable copy;
4. restore the data into the disposable copy;
5. confirm the known test data is present;
6. write down any application-specific restore steps.

This is much more valuable than simply seeing green backup jobs.

## 9. Recommended backup matrix

| Data | Destination | Frequency | Restore tested? |
|---|---|---:|---:|
| Coolify `APP_KEY` | password/secrets manager | after install/change | yes |
| Coolify SSH keys | encrypted off-host backup | after key changes | yes |
| Coolify instance DB | R2 | daily | yes |
| Application DBs | R2 | daily or better | yes |
| Persistent mounts | R2 | daily/weekly based on change rate | yes |
| Whole VPS | OVH Automated Backup | daily | yes |
| Pre-change rollback | OVH snapshot | before risky changes | when used |

## 10. Backup failure is an alert

A failed backup should not be a log entry you discover months later.

Configure Coolify notifications for at least:

- backup failures;
- deployment failures;
- server/container health where useful.

If email/notification delivery itself lives on this VPS, use an external notification path for infrastructure failures where practical.

## Done when

- [ ] `APP_KEY` exists outside the VPS
- [ ] Coolify instance DB is backed up to R2
- [ ] every important database has its own R2 backup
- [ ] every irreplaceable volume/directory is identified and backed up
- [ ] OVH daily Automated Backup is verified
- [ ] `qemu-guest-agent` is active if supported
- [ ] one Coolify restore has been tested
- [ ] one real application-data restore has been tested

Next: [06. Operations and upgrades](06-operations.md)

## References

- Coolify restore: https://coolify.io/docs/core/backup-and-recovery/instance-restore
- Coolify R2: https://coolify.io/docs/core/s3-storage/r2
- Coolify storage backups: https://coolify.io/docs/core/persistent-storage/storage-mounts/backups
- OVH automated VPS backup: https://docs.ovhcloud.com/en/guides/bare-metal-cloud/virtual-private-servers/using-automated-backups-on-a-vps
- OVH VPS snapshots: https://docs.ovhcloud.com/en/guides/bare-metal-cloud/virtual-private-servers/using-snapshots-on-a-vps
