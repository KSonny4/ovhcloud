# 07. Deploy OmniRoute safely on Coolify

OmniRoute is a good fit for this Coolify VPS, but treat it as a **stateful single-replica service**.

## Target architecture

```text
Clients / agents
      |
Cloudflare DNS + proxy
      |
https://omniroute.example.com
      |
Coolify reverse proxy
      |
OmniRoute :20128
      |\
      | `-- Redis on private Docker network
      |
      `-- /app/data persistent volume
               |
               `-- daily stopped-container archive -> Cloudflare R2
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

Keep Redis on the internal Docker network. It does not need a public host port for normal Coolify operation.

Expected relationship:

```text
OmniRoute -> redis://redis:6379
```

If the Compose definition includes a Redis data volume, keep it persistent as well. The SQLite `/app/data` volume remains the critical application state to protect first.

Never publish an unauthenticated Redis on `0.0.0.0:6379`.

## 3. Deploy through Coolify

Preferred approach: deploy OmniRoute as a Docker Compose resource so the application and Redis sidecar stay together.

Use either:

- the upstream OmniRoute repository/image; or
- the maintained `KSonny4/OmniRoute` fork when you need your fork-specific changes.

Whichever source you use, verify these invariants before pressing Deploy:

```text
OmniRoute internal port: 20128
OmniRoute replicas:      1
/app/data:               persistent volume
Redis:                   internal/private
stop grace period:       >= 40s
```

Do not expose port 20128 directly on the VPS when Coolify's reverse proxy can route the hostname internally.

## 4. Domain and Cloudflare

Give OmniRoute an explicit hostname, for example:

```text
omniroute.example.com
```

Route it through Coolify and proxy the DNS record through Cloudflare once origin HTTPS is working.

Use Cloudflare:

```text
SSL/TLS mode: Full (strict)
```

For an API used by agents, do not blindly put an interactive Cloudflare Access login page in front of the endpoint. Either:

- rely on OmniRoute's own API authentication plus Cloudflare proxy/WAF controls; or
- if you deliberately protect the API with Cloudflare Access, use a machine-compatible Access service-token flow for every client.

Cloudflare Access remains strongly recommended for human-only administrative hostnames such as SSH and the Coolify dashboard.

## 5. Secrets required for recovery

The SQLite database can contain encrypted provider credentials. If the associated encryption key is lost, those encrypted fields cannot be recovered from the database alone.

Keep critical OmniRoute secrets outside the VPS in your password/secrets manager, especially any configured:

```text
STORAGE_ENCRYPTION_KEY
API_KEY_SECRET
JWT_SECRET
```

Also keep the Coolify `APP_KEY` outside the VPS because Coolify needs it to decrypt restored Coolify-managed credentials.

Do not commit any of these values to this repository.

## 6. R2 backup for `/app/data`

After OmniRoute is deployed and `/app/data` is visible under Coolify persistent storage:

1. open the OmniRoute application;
2. open `Backups`, or `Configuration -> Persistent Storage` and configure backup for the `/app/data` mount;
3. set frequency to `daily`;
4. select the validated Cloudflare R2 storage;
5. enable S3 upload;
6. enable **Stop containers while creating the archive**;
7. set retention.

Recommended starting retention:

```text
local backups:  3
R2 backups:    30
frequency:     daily
```

Why stop the container for this archive: Coolify's storage backup is file-level, while OmniRoute's SQLite database uses WAL. Stopping the container gracefully before archiving reduces the risk of capturing an inconsistent combination of SQLite/WAL files.

Coolify can stop containers using the selected storage, create the archive, then start them again. Expect a short OmniRoute interruption during this backup window.

## 7. Alternative zero-downtime SQLite backup

OmniRoute's database guide documents SQLite's online backup API for safe live-database copies. If downtime during the daily volume archive later becomes undesirable, build an application-aware backup job using SQLite `.backup` and then store the resulting backup file off-host.

For the initial small deployment, the stopped-container Coolify archive is simpler and safer operationally because it captures the complete `/app/data` directory, not only the main SQLite file.

## 8. Redis backup

Treat Redis as secondary to `/app/data` for recovery.

If the deployed Redis service has a persistent `/data` volume, you may also configure an R2 storage backup for it. This is cheap and can preserve transient/shared state, but do not let Redis backup work distract from protecting:

1. `/app/data`;
2. OmniRoute encryption/authentication secrets;
3. the Coolify instance and its `APP_KEY`.

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

Coolify's storage-backup page currently creates/downloads/deletes archives but does not provide a one-click storage restore. Keep the tested manual restore procedure documented.

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

Do **not** solve OmniRoute load by simply changing replicas from `1` to `2` in Coolify while the deployment uses the stock SQLite database.

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
| Public API ingress | Coolify -> Cloudflare proxy |
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
- Coolify persistent storage: https://coolify.io/docs/applications/configuration/persistent-storage
- Coolify storage backups: https://coolify.io/docs/core/persistent-storage/storage-mounts/backups
- Coolify R2: https://coolify.io/docs/core/s3-storage/r2
- Cloudflare Tunnel: https://developers.cloudflare.com/tunnel/
