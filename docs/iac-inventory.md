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

## Current gaps against the redesign (updated 2026-09-14)

1. RESOLVED 2026-09-14: production state import + authorized live apply done —
   R2-backed encrypted state, `Apply complete`, plan `empty` (verified
   continuously by `scripts/verify-live-reconciliation.sh`; latest: 12–13
   resources including the adopted fabric DNS route). Historical note: an
   earlier revision described a remaining Terraform vault-escrow addition;
   that plan was superseded — escrow is owned by `ensure-service-token.sh`
   + the runner lifecycle, and no `vault` provider/resources exist by
   design. Provider authorization is emitted by
   `scripts/tf-env-from-openbao.sh` (env-only, never a file), never hand-populated.
2. RESOLVED 2026-09-14: Cloudflare admin token replaced (with API-Tokens
   Write; mint-grant proven) and R2 keys rotated, both escrowed
   (`ADMIN_CLOUDFLARE`, `COOLIFY_R2` with all four fields), old tokens
   revoked by operator. Transitional states, superseded the same day:
   host `r2.env` (removed for the memory-only `fetch-r2-env.sh` pull) and
   the Coolify `s3_storages` destination (row id 1, deleted after proving
   zero references — no schedules, avatars, or icons point at it).
   Current state: NO R2 credential exists at rest anywhere (host holds
   scripts + accessor token only; secret-bearing R2 dumps purged; OpenBao
   is the sole escrow). Do NOT re-create the destination row.
   R2 key issuance has no Cloudflare API route (verified 10015); future R2
   rotations stay dashboard-minted + escrowed, everything else is
   API-automated. See `docs/secret-rotation.md`.
3. DEFERRED PERMANENTLY by operator decision 2026-09-14 (no paid second
   VPS): a full live fresh-VPS run will not be ordered. Standing in as
   fresh-path evidence are the per-stage live proofs (bootstrap Docker
   checks, Coolify FQDN/firewall/smoke, Tunnel create/delete via API,
   backup install 7/7 clean-target PASS + destroy-restore cycle) plus the
   11/11 dry-run rehearsal and the runner-staging regression gate. If a
   spare host ever becomes available, run the provisioner twice + record
   idempotence/cleanup.
4. Coolify administrator bootstrap via `ROOT_USERNAME/ROOT_USER_EMAIL/ROOT_USER_PASSWORD` is implemented in `scripts/provision-coolify.sh`; the live host already has its admin (`ksonny4@gmail.com`, 1 user) so no live bootstrap is needed. The runner generates + escrows the password when absent.
5. RESOLVED 2026-09-14: nightly `coolify-db` -> R2 timer live and verified
   (14-day retention), and executable rollback
   `scripts/rollback-coolify-backup.sh` reports RESTORE_OK (users=1, admin
   present, probe dropped). The Coolify S3 destination (row id 1, briefly
   registered then deleted 2026-09-14) is NOT part of live state: the host
   timer is the single backup plane. Per-application database/volume schedules attach
   once applications exist (zero app databases on this fresh install).
6. The supported guest OS baseline is version-sensitive: the current host reports Ubuntu 26.04 LTS while the older runbooks mention Ubuntu 24.04 LTS. Fresh bootstrap supports both and verifies Docker itself.

## Safety boundary (validated 2026-09-13)

No reconciliation ran `ovhcloud reinstall`, reboot, terminate, destroy, or credential rotation. Validation used only `ovhcloud vps list/get/ip list --output json`. The service remains `running`, so no recovery/reboot was needed. Terraform resources for the current VPS must be import/read-only or protected with lifecycle rules until a separately authorized replacement workflow exists.
