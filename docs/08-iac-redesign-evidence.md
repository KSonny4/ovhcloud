# IaC redesign evidence

**Goal:** fully IaC-first, noninteractive OVHcloud/Coolify deployment. Only OVH + Cloudflare API authorization is supplied by the operator through OpenBao; everything else is automated, rehearsed, and escrowed.

## Live-state reconciliation (read-only, 2026-09-13)

- OVH `vps-1525c977.vps.ovh.net`: `running`, `vps-2027-model2` (`VPS-2 2027`), 4 vCores / 8192 MiB / 75 GB SSD, `Region OpenStack: os-uk2` (London UK2), netboot `local`, lock `none`.
- Primary IPs: IPv4 `57.129.155.203` (gateway `57.129.155.1`), IPv6 `2001:41d0:801:2000::3663` (gateway `2001:41d0:801:2000::1`).
- Commands used (no mutation): `ovhcloud vps list/get/ip list --output json`.
- No `reinstall`, reboot, stop, terminate, destroy, or credential rotation was performed.

## Terraform reconciliation

- Encrypted, locked production backend declared in `infra/terraform/versions.tf` (`backend "s3" {}`); operator values live in ignored `backend.hcl` (see `backend.hcl.example`). Disposable rehearsal uses `-backend=false` local state only.
- Import workflow documented in `infra/terraform/imports.tf.example` (ignored `imports.tf` at apply time): Tunnel, both CNAMEs, both Access apps, OTP provider, machine service token, existing R2 bucket. Live IDs come from provider discovery, never hardcoded.
- Lifecycle guards: `prevent_destroy = true` on `ovh_vps.platform` (when provisioned), the `coolify-admin` Tunnel, the OTP provider, and the R2 bucket.
- Cloudflare model matches live state: Tunnel-backed CNAMEs (not origin A), declared ingress (`coolify.<domain>` → `http://localhost:8000`, `ssh.<domain>` → `ssh://localhost:22`, fallback 404), human email policy retained, machine `non_identity` service-token policy on the dashboard, OTP provider, service-token escrow via `vault_kv_secret_v2.access_service_token`.

## Fresh-host automation (preserved VPS is never a target)

| Stage | Script | Proof |
| --- | --- | --- |
| Ubuntu/Docker-ready guest | `scripts/bootstrap-vps.sh` | version-aware (24.04/26.04), idempotent, key-only SSH, swap, UTC; `--dry-run` passes on macOS rehearsal |
| Coolify | `scripts/provision-coolify.sh` | pinned release (default `4.3.19`), Snap-Docker refusal, skips healthy installs, origin `/login` probe |
| Tunnel + Access | `scripts/configure-tunnel-access.sh` | official cloudflared install, token stays in one command env, service-token `curl` must return 200/302 |
| R2 backups | `scripts/backup-r2-probe.sh` | scoped credentials from OpenBao env only; put/head/get/delete probe; retention/rollback expectations printed |
| Full rehearsal | `scripts/rehearse-fresh-environment.sh` | every fresh script runs twice in dry-run (byte-identical), Terraform gates pass, no plaintext secrets, `graft check` OK, JSON report in `/tmp/ovh-coolify-rehearsal/rehearsal-report.json` |

## Secret boundary

- Operator supplies only OVH + Cloudflare API authorization via OpenBao (`https://secrets.pkubelka.cz`); runner/token handling per `docs/iac-interfaces.md`.
- Derived secrets (SSH, Tunnel, service token, Coolify admin/app key, R2) are generated/escrowed in OpenBao under `secret/projects/ovhcloud/*` and referenced by name only.
- Repository gates scan tracked + untracked files for credential-shaped assignments and private-key bodies; Terraform variables are `sensitive` where required; state is encrypted/locked in production.

## Rollback

1. Restore the prior Terraform state/configuration and DNS records (import blocks are re-usable documentation).
2. Restore Coolify/database/volume data from R2 using the escrowed `APP_KEY` + R2 credential (`docs/05-backup-recovery.md`).
3. Use OVH Automated Backup (daily safety net) or a one-active-at-a-time snapshot only as a temporary pre-change rollback point.
4. Re-run `bash scripts/healthcheck.sh` and the service-token verification after any recovery.

## Operator handoff

- Automated path needs no browser login, KVM, or ad-hoc SSH debugging: `bash scripts/rehearse-fresh-environment.sh` proves it.
- Optional human dashboard use only: log in at `https://coolify.pkubelka.cz` via the OTP/email policy (`ksonny4@gmail.com`).
- Authorized production sequence: `backend.hcl` + `imports.tf` (both ignored) → reviewed `terraform plan` with zero replacements for preserved resources → authorized `terraform apply` → health + service-token + backup verification → evidence recorded here.
