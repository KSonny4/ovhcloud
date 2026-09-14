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

- Tunnel ingress: `coolify.<zone>` → `http://localhost:8000`,
  `ssh.<zone>` → `ssh://localhost:22`, unrelated existing routes preserved.
- DNS CNAMEs (proxied) for both hostnames; refuses to overwrite unrelated
  records.
- Access apps `Coolify Dashboard` / `Coolify SSH Administration` with the
  machine service-token policy (precedence 1) and the `ksonny4@gmail.com`
  email policy (precedence 2); app-level IDPs stay empty per the converged
  Terraform shape.
- Readiness: dashboard `/login` exactly HTTP 200 via service token,
  SSH route policy-gated (301/302/401/403) — only after `cloudflared`
  runs on the target.
- Handoff → generated Terraform → import + apply with a zero-change
  second plan (encrypted R2 backend required; backendless mode refuses
  `--apply`).

## 2. Daily use: SSH through the tunnel (workstation)

```bash
brew install cloudflared  # or your package manager
```

`~/.ssh/config` (adjust the `cloudflared` path from `command -v`):

```sshconfig
Host ovh-cloudflare
    HostName ssh.pkubelka.cz
    User ubuntu
    IdentityFile ~/.ssh/ovh_coolify_ed25519
    ProxyCommand /opt/homebrew/bin/cloudflared access ssh --hostname %h
```

Access authenticates you, then the native SSH session establishes. Public
TCP 22 stays closed; the daemon listens locally for Coolify and the tunnel.

## 3. R2 backup storage (the single dashboard exception)

The bucket is Terraform-owned (`cloudflare_r2_bucket.backups`,
`ovh-coolify-backups`, EEUR, private). R2 S3 keys have **no Cloudflare API
route** (verified: every issuance path returns `10015`), so the one
operator dashboard action in the whole platform is minting the keypair
(R2 → bucket → Object Read & Write) and escrowing all four fields at
`secret/projects/ovhcloud/COOLIFY_R2` (`access_key_id`,
`secret_access_key`, `bucket`, `endpoint`). Rotation procedure:
[secret-rotation.md](secret-rotation.md). Keys travel memory-only on every
run; nothing R2 touches disk. There is deliberately **no Coolify S3
destination** (row deleted 2026-09-14; do not re-create it).

## 4. Wildcard applications (opt-in)

`manage_application_wildcard=false` by default. Enabling it is an explicit
Terraform + operator decision (A-record wildcard to the origin), not a
dashboard click.

## Done when

- [x] Tunnel connector healthy (`systemctl is-active cloudflared`)
- [x] CNAMEs resolve to the Tunnel; Access gates both hostnames
- [x] dashboard 200 via service token; SSH route gated
- [x] generated IaC adopted with zero-change plan
- [x] no origin A records; no Coolify S3 destination
- [x] workstation SSH via tunnel works

Next: [05. Backups and recovery](05-backup-recovery.md)

## Appendix: break-glass (automation unavailable)

If the API path is down, the dashboard equivalents are: Tunnels → create +
install `cloudflared` with the token (`--token-file`, 0600, never argv);
DNS → CNAME to `<tunnel-id>.cfargotunnel.com`, proxied; Access → self-hosted
apps with the two policies above. Reconcile into Terraform immediately after
(`adopt-fresh-edge.sh --handoff`), because hand-made edge drifts on the next
plan. Never point dashboard/SSH hostnames at origin A records, and never
create a Coolify S3 destination.

## References

- Cloudflare Tunnel: https://developers.cloudflare.com/tunnel/
- Cloudflare SSH through Access: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/ssh/ssh-cloudflared-authentication/
