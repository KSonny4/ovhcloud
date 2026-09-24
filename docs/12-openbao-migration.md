# OpenBao to Nomad migration

## Status and current stop conditions

The Nomad job and Neon-to-R2 backup implementation are prepared but neither
is live. Do not start a Nomad OpenBao allocation on the shared database or
move the service hostname until the existing node is HA-configured, private
two-way cluster traffic is proven, and Nomad administration is available.

Nomad Variables protect values with Nomad's keyring, but Nomad's default
AEAD key encryption key is held in Raft. The Raft snapshot and the Nomad
recovery material therefore remain part of this service's secret recovery
boundary; this is a known limitation of the existing single-node platform.

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

## HA-assisted migration order

1. Establish a private network path between Pi and OVH. Define the Nomad
   host network `openbao-cluster` on the private interface only, allow TCP
   `8201` only between the two Bao hosts, and prove both directions before
   proceeding. Keep the API listener on OVH loopback `8200`. Current probes
   fail this gate.
2. Configure Pi OpenBao for PostgreSQL HA while it remains the public leader.
   Confirm its existing storage table and secret reads still work.
3. Store the PostgreSQL connection URL in Nomad Variable
   `nomad/jobs/openbao/openbao/server` with the `connection_url` item. The
   task's Nomad workload identity reads this job-owned path; a 0600 template
   file loads `BAO_PG_CONNECTION_URL` into the task. The job specification
   and job history contain only the variable path.
4. Run `jobs/openbao.nomad.hcl` with the private cluster address.
   Unseal the Nomad node using operator-held Shamir shares in the approved
   secure terminal. Never put share values in Nomad, Git, or this runbook.
5. Verify both nodes report HA enabled and a stable leader over Neon. Write a
   synthetic marker through the public Pi endpoint and confirm readback from
   the Nomad node.
6. Change the existing Cloudflare Tunnel route for
   `secrets.pkubelka.cz` to the Nomad loopback API only after step 5 passes.
   Verify authenticated API behavior and a synthetic write/read/delete
   through the public hostname. Keep the Pi running as rollback standby.
7. Keep Pi as rollback until an R2 backup has completed and its isolated
   restore has passed. Roll back by restoring the tunnel route to Pi while
   that node remains healthy.
8. After the OpenBao 2.6.2 backup and restore proof, patch both nodes to
   OpenBao 2.6.3 as a separate rolling change and repeat the HA and API
   checks.

## First restore proof

Download the R2 dump and manifest to an isolated PostgreSQL 18 instance.
Compare bytes and SHA-256 with the manifest, restore with `pg_restore`, and
start an isolated OpenBao 2.6.2 instance against that database. An operator
unseals it with held shares and verifies a synthetic marker. Delete the
disposable database and any temporary Neon branch after the proof.

Do not mark the backup or migration complete until the restore and public
endpoint checks pass. A created R2 object, running Nomad allocation, or
successful health check alone is not sufficient proof.
