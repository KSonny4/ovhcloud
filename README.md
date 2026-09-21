# OVH VPS platform

Opinionated runbook for turning a fresh OVHcloud VPS into a small self-hosted application platform with Nomad.

**Last verified:** 2026-09-18 (Nomad-only; retired previous control plane)

## Start here

Read [`CONTEXT.md`](CONTEXT.md) for the architectural invariants, then use the [deployment plan](docs/deployment-plan.md) for the evidence table and non-live IaC handoff. If you have just bought the VPS and nothing is configured yet, follow:

**[00. From zero to a working Nomad VPS](docs/00-quickstart.md)**

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
   |-- Nomad (server + client, single node)
       |-- jobs: edge/reverse proxy + TLS
       |-- jobs: apps
       |-- jobs: workers
       |-- jobs: databases
       `-- scheduled backups -> Cloudflare R2
```

This repository intentionally contains **no IP addresses, passwords, tokens, private SSH keys, R2 credentials, Cloudflare Tunnel tokens or Nomad bootstrap material**. It is public infrastructure documentation only.

## Full runbook

The implementation handoff, evidence table, IaC boundaries and authorized-apply sequence are in [the deployment plan](docs/deployment-plan.md).

1. [From zero to a working Nomad VPS](docs/00-quickstart.md)
2. [Prepare the OVH VPS](docs/01-ovh-vps.md)
3. [Secure and bootstrap Ubuntu](docs/02-host-bootstrap.md)
4. [Install and configure Nomad](docs/03-nomad.md)
5. [Configure Cloudflare DNS, Tunnel/Access and R2](docs/04-cloudflare.md)
6. [Configure backups and test recovery](docs/05-backup-recovery.md)
7. [Operate and upgrade the server](docs/06-operations.md)
8. [Run a private Docker registry](docs/09-docker-registry.md)
9. [Cut over the live host (operator-gated)](docs/10-cutover.md)

There is also a read-only [`scripts/healthcheck.sh`](scripts/healthcheck.sh) for routine server checks.

## Deploying workloads

The platform is live: Nomad serves at `https://nomad.pkubelka.cz`
(sign in with Cloudflare Access OTP as `ksonny4@gmail.com`). Apps ship as
Nomad jobspec files deployed with `nomad job run`; every job lands as
Docker containers behind the Cloudflare Tunnel (the VPS opens no public
web ports — the tunnel is the sole public edge).

### Path A — jobspec from a Docker image (fastest for one-off services)

Best for: Docker images, databases (Postgres, Redis, MySQL), quick
experiments.

1. Write (or copy) a jobspec under `jobs/` (see `docs/03-nomad.md` for
   the minimal template): image, domain (e.g. `myapp.pkubelka.cz`),
   environment variables (rendered from OpenBao at deploy time — never
   bake secrets into images), and CPU/memory limits (this is a small
   host; set limits so one app cannot starve the rest).
2. Run `nomad job run jobs/myapp.nomad.hcl` and watch the allocation
   go healthy (`nomad job status myapp`).
3. Expose it publicly: add the DNS record and the tunnel ingress route
   for the new hostname (DNS CNAME plus a tunnel ingress entry pointing
   at the origin), then verify `https://myapp.pkubelka.cz` serves
   through Cloudflare.

### Path B — git-stored jobspecs (best for your own code)

Best for: anything you develop — reviewable deploys, with rollbacks.

1. Keep the jobspec in the app repo (private repos via deploy key —
   smallest practical scope, never personal keys on the VPS).
2. Deploy with `nomad job run`; each prior job version is kept, so a bad
   deploy rolls back with `nomad job revert`.
3. Set domain, secrets (OpenBao-rendered), and resource limits as in
   Path A.

### After any deploy

- Confirm the app is reachable at its public URL and healthy in the
Nomad UI (`nomad job status`).
- Nightly backups cover app volumes/databases automatically (host timer
→ R2); a brand-new stateful app is covered from its first night — but a
backup untested by restore is not trusted (see the
[backup runbook](docs/05-backup-recovery.md)).
- If the app needs secrets that must survive a rebuild from scratch
(e.g. encryption keys, not just DB passwords), escrow them in OpenBao
(mark `env_escrowed` in manifests; re-inject via `fetch-app-secrets.sh`)
— never commit them.

Do not skip the backup/recovery section. A Nomad snapshot does not contain application, database and volume data — those ride the host timer to R2.

## Recommended baseline

### VPS

Start with the VPS already purchased. A 2-core / 4 GB machine is enough to start Nomad and a few light services. Upgrade to 4 cores / 8 GB when builds, databases or multiple services begin competing for memory/CPU.

For a 4 GB VPS, configure a **2 GB swap file** with low swappiness. It is a safety buffer for short memory spikes, not a substitute for RAM. Sustained swap use or OOM kills mean the host needs tuning or more memory.

OVH supports in-place upgrades to a larger VPS configuration. Treat downsizing as a migration to a new smaller VPS.

### Operating system

Use **Ubuntu 24.04 LTS** on a fresh server; Nomad ships as a single static binary plus a systemd unit (see `docs/03-nomad.md`).

### Human access

Use:

- a dedicated ED25519 SSH key;
- Cloudflare Tunnel + Cloudflare Access for normal SSH administration;
- OVH KVM/rescue mode as the emergency path.

The tunnel is outbound-only from the VPS. After it is verified, public TCP 22 can be removed from the normal access path.

Do not rely on password SSH.

### Public ports

For the normal Nomad web-app architecture used by this runbook:

| Port | Public? | Purpose |
|---|---:|---|
| 80/tcp | no (UFW deny) | Origin-only: serves tunneled app traffic (Traefik) via Cloudflare Tunnel |
| 443/tcp | no (UFW deny) | Reserved; no public listener |
| 22/tcp | no after bootstrap | Human SSH goes through Cloudflare Tunnel + Access |
| 4646/tcp | no after setup | Nomad HTTP API/UI origin, loopback-only, served through the Tunnel |
| 4647/tcp | no after setup | Nomad RPC, loopback-only |
| 4648/tcp | no after setup | Nomad Serf, loopback-only |

The origin exposes no public web ports: Cloudflare is the sole public edge
and every hostname resolves to the Tunnel. During initial installation, 22
and 8000 may temporarily be reachable; direct public access to
22/4646/4647/4648 is closed once Cloudflare administrative access and the
Nomad UI over HTTPS are verified, and 80/443 stay denied at the host
firewall by design (`scripts/ensure-docker-firewall.sh` enforces this).

## Security principles

1. **Keys only for SSH.** Keep `PermitRootLogin prohibit-password`; no control-plane component needs SSH into localhost.
2. **Cloudflare Access for human administration.** Run `cloudflared` on the VPS and route an SSH hostname to `localhost:22`; require Cloudflare Access authentication.
3. **Provider firewall first.** Use OVH network controls where available. Docker-published ports can bypass normal UFW input rules, so do not assume `ufw deny` protects an exposed Docker port.
4. **Expose only what is deliberate.** Public reachability lives at the Cloudflare edge; the origin holds no public listeners. Databases and administration interfaces stay private.
5. **Back up off-machine.** The host backup timer is the single backup plane to Cloudflare R2 (memory-only credentials); object-storage destinations managed by the old control plane are gone.
6. **Test restores.** A backup that has never been restored is not trusted.
7. **Keep secrets out of Git.** Store the Nomad bootstrap material, Cloudflare Tunnel token, R2 keys and other credentials in OpenBao (names/placeholders only in Git).

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
- [ ] Nomad installed (server + client, single node)
- [ ] Nomad ACL bootstrapped, token escrowed in OpenBao
- [ ] gossip encryption key escrowed in OpenBao
- [ ] UI moved to HTTPS hostname (`nomad.pkubelka.cz`)
- [ ] direct 4646/4647/4648 public access closed (loopback-only)
- [ ] application wildcard DNS configured if wanted
- [ ] Cloudflare R2 storage configured
- [ ] Nomad snapshots scheduled (`nomad operator snapshot save` → R2)
- [ ] database backups configured
- [ ] persistent volume/directory backups configured where needed
- [ ] one restore test completed
- [ ] disk/RAM/CPU monitoring enabled

## Official references

- OVHcloud VPS getting started: https://docs.ovhcloud.com/en/guides/bare-metal-cloud/virtual-private-servers/starting-with-a-vps
- OVHcloud VPS security: https://docs.ovhcloud.com/en/guides/bare-metal-cloud/virtual-private-servers/secure-your-vps
- OVHcloud VPS upgrades: https://docs.ovhcloud.com/en/guides/bare-metal-cloud/virtual-private-servers/upgrade-resources
- Nomad install: https://developer.hashicorp.com/nomad/docs/install
- Nomad job spec: https://developer.hashicorp.com/nomad/docs/job-specification
- Nomad ACL bootstrapping: https://developer.hashicorp.com/nomad/docs/secure/acl/bootstrap
- Nomad snapshots: https://developer.hashicorp.com/nomad/docs/commands/operator/snapshot
- Cloudflare Tunnel: https://developers.cloudflare.com/tunnel/
- Cloudflare SSH through Access: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/ssh/ssh-cloudflared-authentication/
- Docker firewall behaviour: https://docs.docker.com/engine/network/packet-filtering-firewalls/
