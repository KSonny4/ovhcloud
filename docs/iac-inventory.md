# IaC reconciliation inventory

**Purpose:** current-state inventory for the noninteractive OVHcloud/Nomad
redesign. This file contains identifiers and observed state only; it does
not contain provider credentials, tokens, private keys, or generated secret
values. Retired-plane captures (2026-09-13…17) are archived untouched in
`evidence-archive/`; rows below describe the Nomad plane (M5 cutover
verifies each row live).

## Operator inputs and secret boundary

- Public zone: `pkubelka.cz` (Cloudflare zone ID is supplied to Terraform through provider discovery/variables).
- Canonical UI: `nomad.pkubelka.cz`.
- Human UI policy: `ksonny4@gmail.com`.
- Provider authorization is retrieved from the existing OpenBao instance at `https://secrets.pkubelka.cz`.
- The current deployment credential is escrowed under `secret/projects/ovhcloud/ADMIN_CLOUDFLARE` (field name: `ADMIN_CLOUDFLARE`, Zone-DNS + Account Tunnel/Access/R2 + IdP grants). Historical note: an earlier `CF_DEPLOY_TOKEN` field was superseded during rotation the same day and revoked; the automation contract normalizes provider inputs at its OpenBao boundary and reads only `ADMIN_CLOUDFLARE`.
- Derived values, including SSH, Tunnel, service-token, Nomad, and backup credentials, are generated or escrowed in OpenBao and are never committed.

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
| Nomad | 2.0.6 single server+client (target; M5 cutover verifies members/jobs) | Provision via `scripts/provision-nomad.sh`; retired plane archived |
| cloudflared | 2026.9.1, enabled/active | Replace manual install with bootstrap automation |

## Cloudflare edge and administration (target; M5 verifies live)

Tunnel `nomad-admin` (same tunnel object, renamed at apply; `b145382e-d1cc-4e60-b910-3de56fa9ce2c`, healthy)
carries this ingress (catch-all `http_status:404` last):

| Hostname | Origin service | Notes |
| --- | --- | --- |
| `nomad.pkubelka.cz` | `http://localhost:4646` | UI + API; Access human OTP + machine service token |
| `ssh.pkubelka.cz` | `ssh://localhost:22` | Access human OTP + machine service token |
| `fabric.pkubelka.cz` | `https://localhost:443` | No Access app |
| `graph-dispatcher.pkubelka.cz` | `https://localhost:443` | No Access app |
| `omniroute.pkubelka.cz` | `http://localhost:80` | Staging API, no Access app |
| `omni.pkubelka.cz` | `http://localhost:80` | Production API (cut over 2026-09-14), no Access app |
| `registry.pkubelka.cz` | `http://localhost:80` | Private registry (live 2026-09-17), no Access app |

Proxied DNS (zone `pkubelka.cz`; all CNAMEs below point at `nomad-admin`'s `<tunnel-id>.cfargotunnel.com` unless noted): `nomad`, `ssh`, `fabric`, `graph-dispatcher` (+`www`), `keeper`, `omniroute`, `omni`, `registry`; other tunnels serve `recorder`/`trading` (`af70d44…`), `dark`/`dark-dev`/`stremio` (`ef0c9d3…`), `secrets` (`612f43c…`); `forms` → Pages, apex/`pkubelka.cz` → Pages; `llm-quota`/`radar` are `AAAA 100::` placeholders. The account contains unrelated existing tunnels, DNS records, and Access apps — do not claim or destroy them; scope Terraform by explicit names/IDs.

| Resource | Current state | IaC requirement |
| --- | --- | --- |
| Nomad UI Access app | Self-hosted app for `nomad.pkubelka.cz`; email allow policy for `ksonny4@gmail.com` | Retain human UI policy |
| SSH Access app | Self-hosted app for `ssh.pkubelka.cz`; email allow policy for `ksonny4@gmail.com` | Scoped service-token machine policy for verification |
| R2 | Account API reports R2 enabled; bucket `ovh-host-backups` (migrated from the retired name at M5; EEUR, Standard) | Terraform manages the bucket; scoped S3 credential issuance is blocked on a fresh full-access token (see gaps) |

## Nomad job inventory (target; M5 cutover registers)

Workloads run as Nomad jobs (one allocation each for stateful services),
replacing the retired plane's application table (archived). Expected jobs
at cutover: `fabric`, `omniroute` (serves `omni.` + `omniroute.`),
`omniroute-obs`, `omniroute-watcher`, `registry` (`registry:2`, serves
`registry.pkubelka.cz`), `graph-dispatcher`, `keeper`, `llm-quota`,
`edge-proxy` (Host routing to `:80`). Triage at cutover: the pre-existing
`registry:3` duplicate and the unhealthy `llm-quota2` equivalent — neither
ships until healthy. See `docs/03-nomad.md` for the jobspec pattern and
`docs/09-docker-registry.md` §7 for the registry record.

## Secret escrow map (names only — values live in OpenBao, never in Git)

| OpenBao path | Fields | Consumers |
| --- | --- | --- |
| `secret/projects/ovhcloud/ADMIN_CLOUDFLARE` | `ADMIN_CLOUDFLARE` (API token) | Terraform loader, Cloudflare API automation |
| `secret/projects/ovhcloud/OVH_API` | `application_key`, `application_secret`, `consumer_key`, `endpoint` | `ovh_cli` read-only discovery |
| `secret/projects/ovhcloud/NOMAD_BOOTSTRAP` | `acl_token`, `acl_accessor`, `gossip_key` | Nomad bootstrap and recovery |
| `secret/projects/ovhcloud/EDGE_TUNNEL_SECRET` | `tunnel_secret` | Terraform loader (preserved `nomad-admin` singleton) |
| `secret/projects/ovhcloud/EDGE_TUNNEL_<NAME>` | `tunnel_id`, `tunnel_token` | Per-target tunnel creation (fresh hosts) |
| `secret/projects/ovhcloud/EDGE_TUNNEL_TOKEN` | `tunnel_token` | Break-glass reinstall only (no automation reads it) |
| `secret/projects/ovhcloud/BACKUP_R2` | `access_key_id`, `secret_access_key`, `bucket`, `endpoint` | Host-timer backup plane + restore probe |
| `secret/projects/ovhcloud/EDGE_ACCESS_SERVICE_TOKEN` | `client_id`, `client_secret` | Machine edge access (noninteractive verification, API calls) |
| `secret/projects/ovhcloud/PROVISION_SSH_PRIVATE_KEY` / `PROVISION_SSH_PUBLIC_KEY` | key material | Guest bootstrap, provisioner machine connection |
| `secret/projects/ovhcloud/OMNIROUTE` | `STORAGE_ENCRYPTION_KEY`, `API_KEY_SECRET`, `JWT_SECRET` | OmniRoute apps (escrow-recoverable restore) |
| `secret/projects/ovhcloud/REGISTRY` | `htpasswd`, `http_secret`, `username`, `password` | Private registry auth + smoke verify (live 2026-09-17) |

Operator cutover note (M5): Bao entries under retired names are duplicated
to the names above before the cutover, verified by readback, and the old
entries are deleted only after the Nomad plane proves healthy.

## Current gaps against the redesign (updated 2026-09-18)

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
   (`ADMIN_CLOUDFLARE`, `BACKUP_R2` with all four fields — Bao entry renamed
   at the Nomad cutover), old tokens revoked by operator. Transitional states,
   superseded the same day: host `r2.env` (removed for the memory-only
   `fetch-r2-env.sh` pull) and the retired plane's object-storage
   destination (row id 1, deleted after proving zero references).
   Current state: NO R2 credential exists at rest anywhere (host holds
   scripts + accessor token only; secret-bearing R2 dumps purged; OpenBao
   is the sole escrow). Do NOT re-create a control-plane destination.
   R2 key issuance has no Cloudflare API route (verified 10015); future R2
   rotations stay dashboard-minted + escrowed, everything else is
   API-automated. See `docs/secret-rotation.md`.
3. DEFERRED PERMANENTLY by operator decision 2026-09-14 (no paid second
   VPS): a full live fresh-VPS run will not be ordered. Standing in as
   fresh-path evidence are the per-stage live proofs (bootstrap Docker
   checks, Nomad FQDN/firewall/smoke at cutover, Tunnel create/delete via
   API, backup install clean-target PASS + destroy-restore cycle) plus the
   dry-run rehearsal and the runner-staging regression gate. If a
   spare host ever becomes available, run the provisioner twice + record
   idempotence/cleanup.
4. Nomad ACL bootstrap via `scripts/provision-nomad.sh` (automatic escrow
   to `NOMAD_BOOTSTRAP`); no live bootstrap password exists on this plane.
   The runner generates + escrows the token and gossip key when absent.
5. PENDING M5: nightly Nomad snapshot -> R2 timer and executable probe
   `scripts/rollback-nomad-snapshot.sh` must report RESTORE_OK at the
   cutover drill. The retired plane's 2026-09-14 probe proof is archived
   and does not cover the Nomad plane. Per-application database/volume
   schedules attach once applications exist as jobs.
6. The supported guest OS baseline is version-sensitive: the current host reports Ubuntu 26.04 LTS while the older runbooks mention Ubuntu 24.04 LTS. Fresh bootstrap supports both and verifies Docker itself.
7. OPEN 2026-09-17: `registry.pkubelka.cz` DNS + tunnel ingress were created via Cloudflare API outside Terraform state. Before the next `terraform apply`, import both (exact commands in `docs/09-docker-registry.md` §7) and require an empty plan — otherwise apply will fight live state.
8. OPEN (carried): consolidate the two registries (proven `registry:2.8.3`
   vs pre-existing `registry:3`) and triage the unhealthy `llm-quota`
   second instance at cutover. Neither ships as a Nomad job until healthy.

## Safety boundary (validated 2026-09-13)

No reconciliation ran `ovhcloud reinstall`, reboot, terminate, destroy, or credential rotation. Validation used only `ovhcloud vps list/get/ip list --output json`. The service remains `running`, so no recovery/reboot was needed. Terraform resources for the current VPS must be import/read-only or protected with lifecycle rules until a separately authorized replacement workflow exists.
