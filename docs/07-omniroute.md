# 07. Deploy OmniRoute safely on Nomad

OmniRoute is a good fit for this Nomad VPS, but treat it as a **stateful single-replica service**. Its public hostname must use the approved canonical domain recorded in `docs/deployment-plan.md`; `example.com` below is only a documentation placeholder.

## Target architecture

```text
Clients / agents
      |
Cloudflare DNS + proxy
      |
https://omniroute.example.com
      |
Nomad edge job (Host routing)
      |
OmniRoute :20128
      |\
      | `-- Redis sidecar task (same group, private)
      |
      `-- /app/data host volume
               |
               `-- daily stopped-allocation archive -> Cloudflare R2
```

Human server administration remains separate:

```text
workstation -> Cloudflare Access -> Cloudflare Tunnel -> localhost:22
```

Do not expose OmniRoute's Redis or host SSH publicly.

## 1. Why OmniRoute needs persistent storage

OmniRoute's Docker deployment stores its primary persistent state under:

```text
/app/data
```

The directory contains the SQLite database and may also contain WAL/shared-memory companions, call-log artefacts and application backups.

The main database is:

```text
/app/data/storage.sqlite
```

OmniRoute uses SQLite in WAL mode. The stock SQLite topology is intended for a single OmniRoute writer/replica.

Therefore:

- mount `/app/data` persistently;
- run **one OmniRoute application replica**;
- do not put multiple OmniRoute replicas against one shared SQLite file;
- use a graceful shutdown timeout of at least 40 seconds as recommended by the upstream Docker guide.

## 2. Redis

Current OmniRoute Compose deployments include Redis for shared cache/rate-limiting behaviour.

Keep Redis as a sidecar task in the same Nomad group. It does not need a public host port for normal Nomad operation.

Expected relationship:

```text
OmniRoute -> redis://redis:6379
```

If the Compose definition includes a Redis data volume, keep it persistent as well. The SQLite `/app/data` volume remains the critical application state to protect first.

Never publish an unauthenticated Redis on `0.0.0.0:6379`.

## 3. Deploy as a Nomad job

Preferred approach: deploy OmniRoute as a Nomad group so the application and Redis sidecar stay together (one allocation, shared loopback).

Use either:

- the upstream OmniRoute repository/image; or
- the maintained `KSonny4/OmniRoute` fork when you need your fork-specific changes.

Whichever source you use, verify these invariants before `nomad job run`:

```text
OmniRoute internal port: 20128
OmniRoute count:         1
/app/data:               Nomad host volume
Redis:                   sidecar task, no public port
kill timeout:            >= 40s
secrets:                 template stanza from OpenBao (never plaintext)
```

Do not expose port 20128 directly on the VPS when the Nomad edge job can route the hostname internally.

## 4. Domain and Cloudflare

Give OmniRoute an explicit hostname, for example:

```text
omniroute.example.com
```

Route it through the Nomad edge job and proxy the DNS record through Cloudflare once origin HTTPS is working.

Use Cloudflare:

```text
SSL/TLS mode: Full (strict)
```

For an API used by agents, do not blindly put an interactive Cloudflare Access login page in front of the endpoint. Either:

- rely on OmniRoute's own API authentication plus Cloudflare proxy/WAF controls; or
- if you deliberately protect the API with Cloudflare Access, use a machine-compatible Access service-token flow for every client.

Cloudflare Access remains strongly recommended for human-only administrative hostnames such as SSH and the Nomad UI.

## 5. Secrets required for recovery

The SQLite database can contain encrypted provider credentials. If the associated encryption key is lost, those encrypted fields cannot be recovered from the database alone.

The three OmniRoute secrets are DERIVED (automation-generated, never
dashboard-minted): `scripts/ensure-omniroute-secrets.sh` (invoked by the
runner before the backup stage) reads each field from OpenBao
`secret/projects/nomad/OMNIROUTE` and generates (`openssl rand -base64
48`) + escrows (`bao kv patch`, merge-safe, stdin delivery) whatever is
absent; present values are reused untouched. Values are never printed and
never touch disk. R2 S3 keys remain the single operator-supplied
prerequisite — these three are never operator-supplied.

```text
STORAGE_ENCRYPTION_KEY
API_KEY_SECRET
JWT_SECRET
```

Initial deployment consumes them via `bao kv get -field=<NAME>
secret/projects/nomad/OMNIROUTE` (documented one-liner; the only human
relay in the lifecycle). Every LATER recovery is relay-free: the nightly
manifest marks these vars escrow-recoverable (`env_escrowed`, via the
shipped `scripts/lib/escrowed-app-envs` allowlist) and restore re-injects
them from OpenBao (`scripts/fetch-app-secrets.sh` piped blob into the
recreate run) instead of asking the operator.

Do not commit any of these values to this repository.

## 6. R2 backup for `/app/data`

After OmniRoute is deployed and `/app/data` is visible as a Nomad host volume, the host timer (`host-backup.timer`, see [05](05-backup-recovery.md)) covers it nightly. The archive procedure stops the allocation first:

1. `nomad alloc stop` the OmniRoute allocation (graceful, >= 40 s);
2. tar-snapshot the host volume to the dated R2 key;
3. verify via head-object;
4. restart the job (`nomad job start omniroute`);
5. retention prunes keys older than 14 days (R2) / 3 local.

Recommended starting retention:

```text
local backups:  3
R2 backups:    30
frequency:     daily
```

Why stop the allocation for this archive: the backup is file-level, while OmniRoute's SQLite database uses WAL. Stopping the allocation gracefully before archiving reduces the risk of capturing an inconsistent combination of SQLite/WAL files. Expect a short OmniRoute interruption during this backup window.

## 7. Alternative zero-downtime SQLite backup

OmniRoute's database guide documents SQLite's online backup API for safe live-database copies. If downtime during the daily volume archive later becomes undesirable, build an application-aware backup job using SQLite `.backup` and then store the resulting backup file off-host.

For the initial small deployment, the stopped-allocation archive is simpler and safer operationally because it captures the complete `/app/data` directory, not only the main SQLite file.

## 8. Redis backup

Treat Redis as secondary to `/app/data` for recovery.

If the Redis sidecar has a persistent `/data` volume, the host timer covers it too. This is cheap and can preserve transient/shared state, but do not let Redis backup work distract from protecting:

1. `/app/data`;
2. OmniRoute encryption/authentication secrets;
3. the Nomad snapshots and bootstrap material.

## 9. First restore test

Do this before trusting the setup:

1. add a harmless test OmniRoute configuration item;
2. run the `/app/data` backup manually;
3. verify the execution shows an R2 copy;
4. download the archive or retrieve it from R2;
5. deploy a disposable OmniRoute instance with a new persistent volume;
6. stop the disposable instance;
7. restore the archive contents into its `/app/data` mount;
8. provide the same required encryption/authentication secrets;
9. start it;
10. confirm the known test configuration appears and the DB health check is healthy.

There is no one-click restore on this plane — the tested procedure is `rollback-app-workloads.sh --recreate` plus the `/app/data` archive restore below. Keep the tested manual restore procedure documented.

## 10. Monitoring

At minimum watch:

```text
OmniRoute health endpoint
container restart count
RAM usage
swap usage
SQLite/database health
R2 backup result
VPS disk usage
```

Useful host checks:

```bash
free -h
swapon --show
df -hT
docker stats --no-stream
docker ps
```

If the 4 GB VPS begins regularly swapping, or builds plus OmniRoute cause OOM kills, move to more RAM rather than increasing swap indefinitely.

## 11. Scaling rule

Do **not** solve OmniRoute load by simply changing `count` from `1` to `2` in the jobspec while the deployment uses the stock SQLite database.

The current upstream Docker guidance explicitly treats stock SQLite as single-replica. If you eventually need high availability or horizontal scaling, revisit OmniRoute's persistence architecture first rather than sharing one SQLite file between writers.

## Recommended final settings

| Setting | Baseline |
|---|---|
| OmniRoute replicas | 1 |
| OmniRoute port | internal `20128` |
| `/app/data` | persistent volume |
| Redis | private sidecar/internal network |
| Redis public port | none |
| Graceful stop | >= 40 s |
| `/app/data` backup | daily |
| Stop during archive | yes |
| Local retention | 3 copies |
| R2 retention | 30 copies |
| Public API ingress | Nomad edge job -> Cloudflare proxy |
| Human SSH | Cloudflare Tunnel + Access |
| VPS swap | 2 GB on 4 GB RAM baseline |

## Done when

- [ ] OmniRoute runs as one replica
- [ ] `/app/data` is persistent
- [ ] Redis is not publicly exposed
- [ ] OmniRoute endpoint works through its Cloudflare hostname
- [ ] required OmniRoute encryption/auth secrets exist outside the VPS
- [ ] `/app/data` daily R2 backup is configured
- [ ] containers stop during the file-level `/app/data` archive
- [ ] local retention is approximately 3 copies
- [ ] R2 retention is approximately 30 copies
- [ ] one manual backup succeeded
- [ ] one disposable restore test succeeded
- [ ] regular swap/OOM monitoring is in place

## References

- OmniRoute Docker guide: https://github.com/diegosouzapw/OmniRoute/wiki/Docker-Guide
- OmniRoute database guide: https://github.com/diegosouzapw/OmniRoute/wiki/Database-Guide
- OmniRoute environment reference: https://github.com/diegosouzapw/OmniRoute/blob/release/v3.8.51/docs/reference/ENVIRONMENT.md
- Nomad host volumes: https://developer.hashicorp.com/nomad/docs/other-specifications/volume/host
- Nomad job rollback: https://developer.hashicorp.com/nomad/docs/commands/job/revert
- Cloudflare Tunnel: https://developers.cloudflare.com/tunnel/
