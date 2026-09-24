# 04. Configure Cloudflare

Cloudflare is the exclusive public DNS/edge provider. The automated path
owns the full edge: per-target Tunnel (`scripts/ensure-tunnel.sh`), ingress
+ DNS + Access wiring (`scripts/wire-fresh-edge.sh`, two-phase:
API wiring first, readiness verification after the connector runs),
generated imports (`scripts/emit-fresh-imports.sh`), and state adoption
with a zero-change assertion (`scripts/adopt-fresh-edge.sh --apply`) —
all invoked by the provisioner (`--stages edge`, see
[00. Quickstart](00-quickstart.md)) and modeled in
`infra/terraform/main.tf`. There are intentionally **no origin A records**:
dashboard and SSH hostnames are CNAMEs to the Tunnel; the fallback is
`http_status:404`.

## 1. Automated path (primary)

What the edge stage creates and verifies (idempotent, fail closed):

- Tunnel ingress: `nomad.<zone>` → `http://localhost:4646`,
  `ssh.<zone>` → `ssh://localhost:22`, unrelated existing routes preserved.
- DNS CNAMEs (proxied) for both hostnames; refuses to overwrite unrelated
  records.
- Access apps `Nomad UI` / `Nomad SSH Administration` with the
  machine service-token policy (precedence 1) and the `ksonny4@gmail.com`
  email policy (precedence 2); app-level IDPs stay empty per the converged
  Terraform shape.
- Readiness: Nomad leader endpoint (`/v1/status/leader`) exactly HTTP 200 via service token,
  SSH route policy-gated (301/302/401/403) — only after `cloudflared`
  runs on the target.
- Handoff → generated Terraform → import + apply with a zero-change
  second plan (encrypted R2 backend required; backendless mode refuses
  `--apply`).

## 2. Daily use: SSH (two routes — pick the right one)

**Tunnel SSH = human workstation path.** It requires browser-based
Cloudflare Access authentication, which agents do not have. An agent
that blocks asking a human to authenticate `ovh-cloudflare` is on the
wrong route — it must switch to direct SSH below instead of treating
the Access login prompt (`302`, `websocket: bad handshake`) as
progress.

### 2a. Tunnel SSH (human workstations only)

```bash
brew install cloudflared  # or your package manager
```

`~/.ssh/config` (adjust the `cloudflared` path from `command -v`):

```sshconfig
Host ovh-cloudflare
    HostName ssh.pkubelka.cz
    User ubuntu
    IdentityFile ~/.ssh/ovh_nomad_ed25519
    ProxyCommand /opt/homebrew/bin/cloudflared access ssh --hostname %h
```

Access authenticates you, then the native SSH session establishes. Public
TCP 22 stays closed; the daemon listens locally for the tunnel only.
First connection opens the browser for Access login — that human step is
the reason this route is unsuitable for agents.

### 2b. Direct SSH (agent path — no Access hop)

Agents use direct SSH to the current primary with the owner-provisioned
key (`ovh_coolify_ed25519`, `ubuntu` user). Resolve the primary IP and
key per deploy from the overlay/issue/journal, or from the OVH API via
Bao `projects/ovhcloud/OVH_API` — node identity is instance data, never
a guess. Labelled fallback (observed 2026-09-24): `148.113.245.89`
(`vps-c85da816`, `os-bhs6`, hostname `ovh-nomad-fresh`). Retired:
`57.129.155.203` (`vps-1525c977`, STOPPED — port 22 times out, do not
use). Nomad `:4646` and registry `:5000` listen on loopback; all agent
HTTP runs on the box over this SSH session, never remote.

## 3. R2 backup storage (the single dashboard exception)

The bucket is Terraform-owned (`cloudflare_r2_bucket.backups`,
`ovh-host-backups`, EEUR, private). R2 S3 keys have **no Cloudflare API
route** (verified: every issuance path returns `10015`), so the one
operator dashboard action in the whole platform is minting the keypair
(R2 → bucket → Object Read & Write) and escrowing all four fields at
`secret/projects/nomad/BACKUP_R2` (`access_key_id`,
`secret_access_key`, `bucket`, `endpoint`). Rotation procedure:
[secret-rotation.md](secret-rotation.md). Keys travel memory-only on every
run; nothing R2 touches disk. There is deliberately **no control-plane
S3 destination** (row deleted 2026-09-14; do not re-create it).

## 4. Wildcard applications (opt-in)

`manage_application_wildcard=false` by default. Enabling it is an explicit
Terraform + operator decision (A-record wildcard to the origin), not a
dashboard click.

## Done when

- [x] Tunnel connector healthy (`systemctl is-active cloudflared`)
- [x] CNAMEs resolve to the Tunnel; Access gates both hostnames
- [x] Nomad leader endpoint 200 via service token; SSH route gated
- [x] generated IaC adopted with zero-change plan
- [x] no origin A records; no control-plane S3 destination
- [x] workstation SSH via tunnel works (human path, §2a)
- [x] agent SSH via direct route documented with derive-not-guess primary (§2b)

Next: [05. Backups and recovery](05-backup-recovery.md)

## Appendix: break-glass (automation unavailable)

If the API path is down, the dashboard equivalents are: Tunnels → create +
install `cloudflared` with the token (`--token-file`, 0600, never argv);
DNS → CNAME to `<tunnel-id>.cfargotunnel.com`, proxied; Access → self-hosted
apps with the two policies above. Reconcile into Terraform immediately after
(`adopt-fresh-edge.sh --handoff`), because hand-made edge drifts on the next
plan. Never point UI/SSH hostnames at origin A records, and never
create a control-plane S3 destination.

## References

- Cloudflare Tunnel: https://developers.cloudflare.com/tunnel/
- Cloudflare SSH through Access: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/ssh/ssh-cloudflared-authentication/
