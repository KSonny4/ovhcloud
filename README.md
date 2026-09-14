# OVH VPS platform

Opinionated runbook for turning a fresh OVHcloud VPS into a small self-hosted application platform with Coolify.

**Last verified:** 2026-09-13

## Start here

Read [`CONTEXT.md`](CONTEXT.md) for the architectural invariants, then use the [deployment plan](docs/deployment-plan.md) for the evidence table and non-live IaC handoff. If you have just bought the VPS and nothing is configured yet, follow:

**[00. From zero to a working Coolify VPS](docs/00-quickstart.md)**

It is the exact first-day sequence. The remaining documents explain each area in more detail and contain recovery/operational notes.

## Target architecture

```text
Internet
   |
Cloudflare
   |-- DNS / reverse proxy for public web apps
   |-- Tunnel + Access for human administration / SSH
   |-- R2 backup storage
   |
OVHcloud VPS
   |-- Ubuntu 24.04 LTS
   |-- OpenSSH, keys only
   |-- cloudflared outbound tunnel
   |-- Coolify
       |-- reverse proxy / TLS
       |-- apps
       |-- workers
       |-- databases
       `-- scheduled backups -> Cloudflare R2
```

This repository intentionally contains **no IP addresses, passwords, tokens, private SSH keys, R2 credentials, Cloudflare Tunnel tokens or Coolify APP_KEY**. It is public infrastructure documentation only.

## Full runbook

The implementation handoff, evidence table, IaC boundaries and authorized-apply sequence are in [the deployment plan](docs/deployment-plan.md).

1. [From zero to a working Coolify VPS](docs/00-quickstart.md)
2. [Prepare the OVH VPS](docs/01-ovh-vps.md)
3. [Secure and bootstrap Ubuntu](docs/02-host-bootstrap.md)
4. [Install and configure Coolify](docs/03-coolify.md)
5. [Configure Cloudflare DNS, Tunnel/Access and R2](docs/04-cloudflare.md)
6. [Configure backups and test recovery](docs/05-backup-recovery.md)
7. [Operate and upgrade the server](docs/06-operations.md)
8. [Deploy OmniRoute safely](docs/07-omniroute.md)

There is also a read-only [`scripts/healthcheck.sh`](scripts/healthcheck.sh) for routine server checks.

## Deploying workloads

The platform is live: Coolify runs at `https://coolify.pkubelka.cz`
(sign in with Cloudflare Access OTP as `ksonny4@gmail.com`). There are two
ways to ship an app; both end up as Docker containers behind the
Cloudflare Tunnel (the VPS opens no public web ports — the tunnel is the
sole public edge).

### Path A — dashboard (fastest for one-off services)

Best for: Docker images, databases (Postgres, Redis, MySQL), quick
experiments. The `fabric` app already on the server was deployed this way.

1. Open the dashboard → pick the `production` environment (inside your
   project) → **New Resource**.
2. Choose **Application → Docker Image** (e.g. `nginx:alpine`, or any
   image), or **Database** for a managed Postgres/Redis/MySQL.
3. Set the **domain** (e.g. `myapp.pkubelka.cz`), environment variables
   (in Coolify's environment config — never bake secrets into images),
   and CPU/memory limits (this is a small host; set limits so one app
   cannot starve the rest).
4. Press **Deploy**.
5. Expose it publicly: add the DNS record and the tunnel ingress route
   for the new hostname (same pattern as the existing `fabric` route —
   DNS CNAME plus a tunnel ingress entry pointing at the origin), then
   verify `https://myapp.pkubelka.cz` serves through Cloudflare.

### Path B — git-connected (best for your own code)

Best for: anything you develop — push to deploy, with rollbacks.

1. Dashboard → `production` → **New Resource → Application → Git
   Repository** (public repo directly; private repos via the GitHub App
   or a deploy key — smallest practical scope, never personal keys on
   the VPS).
2. Pick the branch and build pack (Nixpacks autodetects most projects;
   Dockerfile if you have one; static for frontend-only).
3. Set domain, environment variables, and resource limits as in Path A.
4. Press **Deploy** once — after that, every `git push` to the tracked
   branch rebuilds and redeploys automatically. Each deployment is kept,
   so a bad push rolls back by redeploying the previous one.

### After any deploy

- Confirm the app is reachable at its public URL and healthy in the
dashboard.
- Nightly backups cover app volumes/databases automatically (host timer
→ R2); a brand-new stateful app is covered from its first night — but a
backup untested by restore is not trusted (see the
[backup runbook](docs/05-backup-recovery.md)).
- If the app needs secrets that must survive a rebuild from scratch
(e.g. encryption keys, not just DB passwords), escrow them in OpenBao
and follow the lifecycle in [Deploy OmniRoute safely](docs/07-omniroute.md)
— that is the pattern for app-secret generate/escrow/re-inject.

Do not skip the backup/recovery section. A Coolify instance backup does not contain all application, database and volume data.

## Recommended baseline

### VPS

Start with the VPS already purchased. A 2-core / 4 GB machine is enough to start Coolify and a few light services. Upgrade to 4 cores / 8 GB when builds, databases or multiple services begin competing for memory/CPU.

For a 4 GB VPS, configure a **2 GB swap file** with low swappiness. It is a safety buffer for short memory spikes, not a substitute for RAM. Sustained swap use or OOM kills mean the host needs tuning or more memory.

OVH supports in-place upgrades to a larger VPS configuration. Treat downsizing as a migration to a new smaller VPS.

### Operating system

Use **Ubuntu 24.04 LTS**. Coolify's automated installer supports Ubuntu LTS releases and recommends a fresh server.

### Human access

Use:

- a dedicated ED25519 SSH key;
- Cloudflare Tunnel + Cloudflare Access for normal SSH administration;
- OVH KVM/rescue mode as the emergency path.

The tunnel is outbound-only from the VPS. After it is verified, public TCP 22 can be removed from the normal access path.

Do not rely on password SSH.

### Public ports

For the normal Coolify web-app architecture used by this runbook:

| Port | Public? | Purpose |
|---|---:|---|
| 80/tcp | no (UFW deny) | Origin-only: serves tunneled app traffic (Traefik) via Cloudflare Tunnel |
| 443/tcp | no (UFW deny) | Reserved; no public listener |
| 22/tcp | no after bootstrap | Human SSH goes through Cloudflare Tunnel + Access |
| 8000/tcp | no after setup | Coolify dashboard origin, served only through the Tunnel |
| 6001/tcp | no after setup | Coolify realtime origin, Tunnel-only |
| 6002/tcp | no after setup | Coolify web terminal origin, Tunnel-only |

The origin exposes no public web ports: Cloudflare is the sole public edge
and every hostname resolves to the Tunnel. During initial installation, 22
and 8000 may temporarily be reachable; direct public access to
22/8000/6001/6002 is closed once Cloudflare administrative access and the
Coolify HTTPS dashboard are verified, and 80/443 stay denied at the host
firewall by design (`provision-coolify.sh` enforces this).

## Security principles

1. **Keys only for SSH.** Keep `PermitRootLogin prohibit-password`, because Coolify uses SSH to manage localhost as well as remote servers.
2. **Cloudflare Access for human administration.** Run `cloudflared` on the VPS and route an SSH hostname to `localhost:22`; require Cloudflare Access authentication.
3. **Provider firewall first.** Use OVH network controls where available. Docker-published ports can bypass normal UFW input rules, so do not assume `ufw deny` protects an exposed Docker port.
4. **Expose only what is deliberate.** Public reachability lives at the Cloudflare edge; the origin holds no public listeners. Databases and administration interfaces stay private.
5. **Back up off-machine.** The host backup timer is the single backup plane to Cloudflare R2 (memory-only credentials); there is deliberately no Coolify S3 destination.
6. **Test restores.** A backup that has never been restored is not trusted.
7. **Keep secrets out of Git.** Store the Coolify `APP_KEY`, Cloudflare Tunnel token, R2 keys and other credentials in a password/secrets manager.

## First-day checklist

- [ ] Ubuntu 24.04 LTS installed
- [ ] dedicated local SSH key generated
- [ ] key-based login verified in a second terminal
- [ ] system fully updated and rebooted if required
- [ ] 2 GB swap configured on a 4 GB VPS
- [ ] Cloudflare Tunnel installed and healthy
- [ ] Cloudflare Access protects the SSH hostname
- [ ] SSH through Cloudflare verified from the workstation
- [ ] public TCP 22 removed/restricted after tunnel verification
- [ ] root SSH configured as `prohibit-password`, not password-enabled
- [ ] OVH recovery/KVM path understood
- [ ] Coolify installed
- [ ] Coolify admin created immediately
- [ ] `/data/coolify/source/.env` backed up securely
- [ ] dashboard moved to HTTPS hostname
- [ ] direct 8000/6001/6002 public access closed
- [ ] application wildcard DNS configured if wanted
- [ ] Cloudflare R2 storage configured
- [ ] Coolify instance backup configured
- [ ] database backups configured
- [ ] persistent volume/directory backups configured where needed
- [ ] one restore test completed
- [ ] disk/RAM/CPU monitoring enabled

## Official references

- OVHcloud VPS getting started: https://docs.ovhcloud.com/en/guides/bare-metal-cloud/virtual-private-servers/starting-with-a-vps
- OVHcloud VPS security: https://docs.ovhcloud.com/en/guides/bare-metal-cloud/virtual-private-servers/secure-your-vps
- OVHcloud VPS upgrades: https://docs.ovhcloud.com/en/guides/bare-metal-cloud/virtual-private-servers/upgrade-resources
- Coolify self-hosted install: https://coolify.io/docs/start-with-self-hosted
- Coolify firewall: https://coolify.io/docs/core/infrastructure/servers/firewall
- Coolify OpenSSH: https://coolify.io/docs/core/infrastructure/servers/openssh
- Coolify DNS: https://coolify.io/docs/core/networking/dns
- Coolify R2: https://coolify.io/docs/core/s3-storage/r2
- Cloudflare Tunnel: https://developers.cloudflare.com/tunnel/
- Cloudflare SSH through Access: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/ssh/ssh-cloudflared-authentication/
- Docker firewall behaviour: https://docs.docker.com/engine/network/packet-filtering-firewalls/
