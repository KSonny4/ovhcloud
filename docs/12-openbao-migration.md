# OpenBao to Nomad migration

## Single-instance move

The requested move uses one OpenBao process at a time against the existing
Neon PostgreSQL database. PostgreSQL HA and OpenBao cluster traffic are not
part of this move. Starting the Nomad allocation while the Pi process is
running would create two writers; stop the Pi process first and keep it
stopped until rollback or the move is accepted.

The production OpenBao 2.6.2 state was backed up to R2 and the dump was
restored into an isolated PostgreSQL 18 instance. The restored OpenBao was
unsealed and an authenticated KV read succeeded. The daily Neon backup is
still not scheduled: its runtime secret entry and reader-policy grant have
not been provisioned.

Nomad Variables protect the PostgreSQL URL with Nomad's keyring. Nomad's
default AEAD key encryption key is held in Raft, so retain the existing
Nomad snapshot and bootstrap material as part of this service's recovery
boundary.

## Neon database backup to Cloudflare R2

`scripts/backup-openbao-db.sh` creates a timestamped Neon point-in-time
branch at backup start, starts a read-write compute, waits for PostgreSQL,
and runs `pg_dump -Fc` against only the `openbao` database. The temporary
branch clones the Neon project while active, including sibling databases;
only `openbao` is exported. The branch is deleted before a complete manifest
is published. The dump and manifest are each checked by R2 object size and
read-back SHA-256. Objects under `openbao/` older than 14 days are pruned.

Runtime fields are read by name from OpenBao
`secret/projects/nomad/OPENBAO_NEON_BACKUP`: `api_key`, `project_id`,
`parent_branch_id`, `database`, `username`, and `password`. The API key must
be scoped to the intended Neon project. R2 fields remain at
`secret/projects/nomad/BACKUP_R2`. The host accessor policy must also grant
read access to the new entry. Neither that entry nor policy change is live;
until provisioned the wrapper fails closed.

The Neon project is PostgreSQL 18. The host installer uses the PostgreSQL
Project's signed APT repository and installs its PostgreSQL 18 client. The
credential wrapper keeps Neon and R2 credentials in process memory and does
not put them in arguments, logs, manifests, or Git.

## Cutover order

1. Store the existing PostgreSQL connection URL in Nomad Variable
   `nomad/jobs/openbao/openbao/server` with the `connection_url` item. The
   task's Nomad workload identity reads this job-owned path; a 0600 template
   file loads `BAO_PG_CONNECTION_URL` into the task. The job specification
   and job history contain only the variable path.
2. Pre-stage the Nomad job and the `secrets.pkubelka.cz` ingress on the
   Nomad tunnel while the public DNS record still points to the Pi tunnel.
   The API listener remains loopback-only on Nomad port 8200.
3. Stop the Pi OpenBao process. Confirm it is stopped before starting the
   Nomad job so only one process writes to Neon.
4. Start one Nomad allocation. The operator unseals it with held Shamir
   shares in the secure terminal; never put shares in Nomad, Git, or this
   runbook. Verify authenticated KV reads through the local Nomad listener.
5. Change the `secrets.pkubelka.cz` DNS CNAME to the Nomad tunnel and verify
   authenticated API reads plus a synthetic write/read/delete through the
   public hostname.
6. Keep the Pi process stopped as rollback. To roll back, stop the Nomad
   allocation, start OpenBao on the Pi, then point the DNS CNAME back to the
   `secrets-openbao` tunnel. Never run both processes against Neon together.
7. After the move, run the verified Neon-to-R2 backup and retain the Pi
   rollback option until the Nomad endpoint is stable.

## First restore proof

Download the R2 dump and manifest to an isolated PostgreSQL 18 instance.
Compare bytes and SHA-256 with the manifest, restore with `pg_restore`, and
start an isolated OpenBao 2.6.2 instance against that database. An operator
unseals it with held shares and verifies a synthetic marker. Delete the
disposable database and any temporary Neon branch after the proof.

Do not mark the migration complete until the restore and public endpoint
checks pass. A created R2 object, running Nomad allocation, or successful
health check alone is not sufficient proof.
