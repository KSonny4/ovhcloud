# Deployment context

This repository is the source of truth for the OVHcloud VPS deployment runbook and its safe, non-live infrastructure plan.

## System boundary

- **OVHcloud VPS** is the origin host and compute provider; the installed `ovhcloud` CLI is the read-only discovery and operator handoff tool for this account.
- **Ubuntu 24.04 LTS + Docker + Coolify** is the host and deployment control plane.
- **Cloudflare** is the only public DNS/edge provider: DNS, proxy/TLS, Tunnel/Access for human administration, and R2 for off-host backups.
- **OmniRoute** is a stateful, single-replica workload with SQLite under `/app/data` and private Redis.
- **External secret manager** owns recovery-critical values; Git and Terraform variables files contain names/placeholders only.

## Invariants

1. The canonical domain is supplied by an authorized operator; `example.com` and similar values are documentation placeholders, never deployable configuration.
2. Public steady-state origin ports are 80/443. SSH and Coolify bootstrap ports are closed or restricted only after their replacement access paths are proven.
3. Cloudflare Access protects human-only administration. Machine API clients use application authentication or an explicit service-token design, not an interactive login page.
4. The Terraform plan is reviewable and non-live by default. A provider apply requires an encrypted state backend, external credentials, an approved domain, and an operator authorization. `ovhcloud` CLI discovery may seed or verify Terraform inputs, but CLI commands that mutate VPS state remain operator-only.
5. Backups are not trusted until a restore proves known data; OVH automated backup is an additional layer, not a replacement for Cloudflare R2.
6. Graft is a context index, not a source of runtime state. Its generated cache stays local and `graft check` is the reproducible freshness gate.

## Vocabulary

- **Origin**: the OVH VPS and its Coolify reverse proxy.
- **Public edge**: Cloudflare DNS/proxy/TLS for application traffic.
- **Admin path**: Cloudflare Tunnel + Access to localhost SSH and restricted admin surfaces.
- **Recovery secret**: a value required to decrypt or restore state, including Coolify `APP_KEY`, OmniRoute encryption/authentication keys, SSH key material, and R2 credentials.
- **Authorized apply**: a human-approved Terraform apply performed only after plan review and secret/state prerequisites are satisfied.
