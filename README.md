# OVH VPS platform

Opinionated runbook for turning a fresh OVHcloud VPS into a small self-hosted application platform with Coolify.

**Last verified:** 2026-09-13

## Target architecture

```text
Internet
   |
Cloudflare
   |-- DNS / optional proxy
   |-- R2 backup storage
   |
OVHcloud VPS
   |-- Ubuntu 24.04 LTS
   |-- OpenSSH, keys only
   |-- Tailscale for human administration
   |-- Coolify
       |-- reverse proxy / TLS
       |-- apps
       |-- workers
       |-- databases
       `-- scheduled backups -> Cloudflare R2
```

This repository intentionally contains **no IP addresses, passwords, tokens, private SSH keys, R2 credentials or Coolify APP_KEY**. It is public infrastructure documentation only.

## The short version

If the VPS is completely fresh, do these in order:

1. [Prepare the OVH VPS](docs/01-ovh-vps.md)
2. [Secure and bootstrap Ubuntu](docs/02-host-bootstrap.md)
3. [Install and configure Coolify](docs/03-coolify.md)
4. [Configure Cloudflare DNS and R2](docs/04-cloudflare.md)
5. [Configure backups and test recovery](docs/05-backup-recovery.md)
6. [Operate and upgrade the server](docs/06-operations.md)

Do not skip the backup/recovery section. A Coolify instance backup does not contain all application, database and volume data.

## Recommended baseline

### VPS

Start with the VPS already purchased. A 2-core / 4 GB machine is enough to start Coolify and a few light services. Upgrade to 4 cores / 8 GB when builds, databases or multiple services begin competing for memory/CPU.

OVH supports in-place upgrades to a larger VPS configuration. Treat downsizing as a migration to a new smaller VPS.

### Operating system

Use **Ubuntu 24.04 LTS**. Coolify's automated installer supports Ubuntu LTS releases and recommends a fresh server.

### Human access

Use:

- a dedicated ED25519 SSH key
- Tailscale for normal SSH administration
- OVH KVM/rescue mode as the emergency path

Do not rely on password SSH.

### Public ports

For the final steady state:

| Port | Public? | Purpose |
|---|---:|---|
| 80/tcp | yes | HTTP and ACME/certificate flow through Coolify proxy |
| 443/tcp | yes | HTTPS through Coolify proxy |
| 22/tcp | preferably no | Human SSH should use Tailscale after bootstrap |
| 8000/tcp | no after setup | Direct Coolify dashboard bootstrap access |
| 6001/tcp | no after setup | Coolify realtime updates when using direct-IP dashboard |
| 6002/tcp | no after setup | Coolify web terminal when using direct-IP dashboard |

During initial installation, 22 and 8000 may temporarily be reachable. Close direct public access to 8000/6001/6002 after the Coolify dashboard has its own HTTPS domain.

## Security principles

1. **Keys only for SSH.** Keep `PermitRootLogin prohibit-password`, because Coolify uses SSH to manage localhost as well as remote servers.
2. **Provider firewall first.** Use OVH network controls where available. Docker-published ports can bypass normal UFW input rules, so do not assume `ufw deny` protects an exposed Docker port.
3. **Expose only 80/443 publicly.** Databases and administration interfaces stay private unless there is a deliberate reason otherwise.
4. **Use Tailscale for administration.** Once verified, public SSH can be removed from the normal access path.
5. **Back up off-machine.** Cloudflare R2 is the default S3-compatible destination in this runbook.
6. **Test restores.** A backup that has never been restored is not trusted.
7. **Keep secrets out of Git.** Store the Coolify `APP_KEY`, R2 keys and other credentials in a password/secrets manager.

## First-day checklist

- [ ] Ubuntu 24.04 LTS installed
- [ ] dedicated local SSH key generated
- [ ] key-based login verified in a second terminal
- [ ] system fully updated and rebooted if required
- [ ] Tailscale installed and reachable
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
- Tailscale Linux install: https://tailscale.com/docs/install/linux
- Docker firewall behaviour: https://docs.docker.com/engine/network/packet-filtering-firewalls/
