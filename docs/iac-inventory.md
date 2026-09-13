# IaC reconciliation inventory

**Purpose:** current-state inventory for the noninteractive OVHcloud/Coolify redesign. This file contains identifiers and observed state only; it does not contain provider credentials, tokens, private keys, or generated secret values.

## Operator inputs and secret boundary

- Public zone: `pkubelka.cz` (Cloudflare zone ID is supplied to Terraform through provider discovery/variables).
- Canonical dashboard: `coolify.pkubelka.cz`.
- Human dashboard policy: `ksonny4@gmail.com`.
- Provider authorization is retrieved from the existing OpenBao instance at `https://secrets.pkubelka.cz`.
- The current deployment credential is escrowed under `secret/projects/ovhcloud/CF_DEPLOY_TOKEN` (field name: `CF_DEPLOY_TOKEN`). The repository must not depend on that field name; the automation contract should normalize provider inputs at its OpenBao boundary.
- Derived values, including SSH, Tunnel, service-token, Coolify, and backup credentials, are generated or escrowed in OpenBao and are never committed.

## OVH origin (validated 2026-09-13, read-only CLI)

| Field | Observed value | Reconciliation rule |
| --- | --- | --- |
| Service | `vps-1525c977.vps.ovh.net` | Preserve and import/read; never replace implicitly |
| State | `running` | Must remain running throughout reconciliation |
| Zone | `Region OpenStack: os-uk2` (`UK`, London UK2, region) | Use as the existing-origin placement |
| Model | `VPS-2 2027` / `vps-2027-model2` / `2027v1` | Record; do not order a replacement |
| Capacity | 4 vCores, 8192 MiB RAM, 75 GB SSD | Record as baseline |
| Netboot | `local` | Do not change boot mode during reconciliation |
| Lock | `locked=false`, reason `none` | Preservation is by lifecycle guard/process, not provider lock |
| IPv4 | `57.129.155.203` (gateway `57.129.155.1`, primary) | Origin metadata only; public traffic should use Cloudflare |
| IPv6 | `2001:41d0:801:2000::3663` (gateway `2001:41d0:801:2000::1`, primary) | Origin metadata only |
| Guest baseline | Ubuntu 26.04 LTS, Docker 29.8.0, 2 GiB swap | Reconcile actual state; fresh bootstrap must be version-aware |
| Coolify | 4.3.19; containers healthy | Preserve and automate equivalent fresh installation |
| cloudflared | 2026.9.1, enabled/active | Replace manual install with bootstrap automation |

## Cloudflare edge and administration

| Resource | Current state | IaC requirement |
| --- | --- | --- |
| `coolify.pkubelka.cz` | Proxied CNAME to `b145382e-d1cc-4e60-b910-3de56fa9ce2c.cfargotunnel.com` | Manage as Tunnel route, not an origin A record |
| `ssh.pkubelka.cz` | Proxied CNAME to the same Tunnel | Manage with Access and machine verification |
| Tunnel `coolify-admin` | ID `b145382e-d1cc-4e60-b910-3de56fa9ce2c`, healthy | Import/manage with declared ingress |
| Tunnel ingress | `coolify.pkubelka.cz` → `http://localhost:8000`; `ssh.pkubelka.cz` → `ssh://localhost:22`; fallback 404 | Declare idempotently |
| Coolify Access app | Self-hosted app for `coolify.pkubelka.cz`; email allow policy for `ksonny4@gmail.com` | Retain human dashboard policy |
| SSH Access app | Self-hosted app for `ssh.pkubelka.cz`; email allow policy for `ksonny4@gmail.com` | Add scoped service-token machine policy for verification |
| R2 | Account API reports R2 enabled; bucket `ovh-coolify-backups` created 2026-09-13 via API (EEUR, Standard) | Terraform must import the existing bucket; scoped S3 credential issuance is blocked on a fresh full-access token (see gaps) |
| Other Cloudflare resources | The account contains unrelated existing tunnels, DNS records, and Access apps | Do not claim or destroy unrelated resources; scope Terraform by explicit names/IDs |

## Current gaps against the redesign

1. The existing Terraform root declares the edge/access/R2 model but production state import (`imports.tf` + `backend.hcl`) remains an authorized operator action; the live R2 bucket `ovh-coolify-backups` (created 2026-09-13, EEUR) is recorded here for that import.
2. Scoped R2 S3 API-token creation has no working v4 API route under the current R2-scoped token (`/r2/api-tokens` and per-bucket credential routes return 404; `/user/tokens` returns 403); the full-access deployment token in OpenBao is stale (`Invalid API Token`). Issuing a fresh scoped Cloudflare token requires the operator's dashboard authorization.
3. The current VPS was bootstrapped imperatively; fresh-host bootstrap is scripted but a paid disposable-VPS rehearsal has not been ordered.
4. Coolify administrator bootstrap via `ROOT_USERNAME/ROOT_USER_EMAIL/ROOT_USER_PASSWORD` is implemented in `scripts/provision-coolify.sh`; the live host already has its admin (`ksonny4@gmail.com`, 1 user) so no live bootstrap is needed.
5. R2 bucket exists; Coolify/R2 backup scheduling + automated restore evidence: live DB backup (`pg_dump -Fc`, 295 KB) and restore probe into a disposable database succeeded 2026-09-13 (`users` count 1, email verified, probe DB dropped, artifacts removed). Full Coolify-scheduled R2 backup wiring still requires the scoped S3 credential (blocked on 2).
6. The supported guest OS baseline is version-sensitive: the current host reports Ubuntu 26.04 LTS while the older runbooks mention Ubuntu 24.04 LTS. Fresh bootstrap supports both and verifies Docker itself.

## Safety boundary (validated 2026-09-13)

No reconciliation ran `ovhcloud reinstall`, reboot, terminate, destroy, or credential rotation. Validation used only `ovhcloud vps list/get/ip list --output json`. The service remains `running`, so no recovery/reboot was needed. Terraform resources for the current VPS must be import/read-only or protected with lifecycle rules until a separately authorized replacement workflow exists.
