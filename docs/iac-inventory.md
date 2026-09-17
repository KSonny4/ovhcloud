# IaC reconciliation inventory

**Purpose:** current-state inventory for the noninteractive OVHcloud/Coolify redesign. This file contains identifiers and observed state only; it does not contain provider credentials, tokens, private keys, or generated secret values.

## Operator inputs and secret boundary

- Public zone: `pkubelka.cz` (Cloudflare zone ID is supplied to Terraform through provider discovery/variables).
- Canonical dashboard: `coolify.pkubelka.cz`.
- Human dashboard policy: `ksonny4@gmail.com`.
- Provider authorization is retrieved from the existing OpenBao instance at `https://secrets.pkubelka.cz`.
- The current deployment credential is escrowed under `secret/projects/ovhcloud/ADMIN_CLOUDFLARE` (field name: `ADMIN_CLOUDFLARE`, Zone-DNS + Account Tunnel/Access/R2 + IdP grants). Historical note: an earlier `CF_DEPLOY_TOKEN` field was superseded during rotation the same day and revoked; the automation contract normalizes provider inputs at its OpenBao boundary and reads only `ADMIN_CLOUDFLARE`.
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

## Cloudflare edge and administration (live 2026-09-17, API-verified)

Tunnel `coolify-admin` (`b145382e-d1cc-4e60-b910-3de56fa9ce2c`, healthy) carries this ingress (catch-all `http_status:404` last):

| Hostname | Origin service | Notes |
| --- | --- | --- |
| `coolify.pkubelka.cz` | `http://localhost:6001`, `:6002`, `:8000` | Dashboard (+realtime); Access human OTP |
| `ssh.pkubelka.cz` | `ssh://localhost:22` | Access human OTP + machine service token |
| `fabric.pkubelka.cz` | `https://localhost:443` | No Access app |
| `graph-dispatcher.pkubelka.cz` | `https://localhost:443` | No Access app |
| `omniroute.pkubelka.cz` | `http://localhost:80` | Staging API, no Access app |
| `omni.pkubelka.cz` | `http://localhost:80` | Production API (cut over 2026-09-14), no Access app |
| `registry.pkubelka.cz` | `http://localhost:80` | Private registry (live 2026-09-17), no Access app |

Proxied DNS (zone `pkubelka.cz`; all CNAMEs below point at `coolify-admin`'s `<tunnel-id>.cfargotunnel.com` unless noted): `coolify`, `ssh`, `fabric`, `graph-dispatcher` (+`www`), `keeper`, `omniroute`, `omni`, `registry`; other tunnels serve `recorder`/`trading` (`af70d44…`), `dark`/`dark-dev`/`stremio` (`ef0c9d3…`), `secrets` (`612f43c…`); `forms` → Pages, apex/`pkubelka.cz` → Pages; `llm-quota`/`radar` are `AAAA 100::` placeholders. The account contains unrelated existing tunnels, DNS records, and Access apps — do not claim or destroy them; scope Terraform by explicit names/IDs.

| Resource | Current state | IaC requirement |
| --- | --- | --- |
| Coolify Access app | Self-hosted app for `coolify.pkubelka.cz`; email allow policy for `ksonny4@gmail.com` | Retain human dashboard policy |
| SSH Access app | Self-hosted app for `ssh.pkubelka.cz`; email allow policy for `ksonny4@gmail.com` | Scoped service-token machine policy for verification |
| R2 | Account API reports R2 enabled; bucket `ovh-coolify-backups` created 2026-09-13 via API (EEUR, Standard) | Terraform must import the existing bucket; scoped S3 credential issuance is blocked on a fresh full-access token (see gaps) |

## Coolify application inventory (live 2026-09-17, edge-API read)

Host: Coolify 4.3.19, server `localhost`, Traefik v3.7 proxy. Projects: `context-fabric`, `omniroute`, `llm-quota`, `graph-engineering`, `keeper`, `docker-registry`.

| Application | Project / env | Type | Status | Notes |
| --- | --- | --- | --- | --- |
| `fabric-stack` | context-fabric | compose | running:healthy | Serves `fabric.pkubelka.cz` |
| `omniroute-compose` | omniroute / production | compose | running:healthy | Serves `omni.pkubelka.cz` + `omniroute.pkubelka.cz` |
| `omniroute-obs` | omniroute / production | compose | running:unknown | Observability stack |
| `omniroute-watcher` | omniroute / production | compose | running:unknown | Watcher |
| `registry` | omniroute / production | docker image (`registry:2.8.3`) | running:unknown, serving proven | Serves `registry.pkubelka.cz`; health shows unknown because authed `/v2/` answers 401 — see `docs/09-docker-registry.md` §7 |
| `graph-dispatcher` | graph-engineering | dockerfile | running:healthy | Serves `graph-dispatcher.pkubelka.cz` |
| `keeper` | keeper | compose | running:unknown | Serves `keeper.pkubelka.cz` |
| `llm-quota` | llm-quota | dockerfile | running:healthy | — |
| `llm-quota2` | llm-quota | dockerfile | **exited:unhealthy** | Needs owner triage (see gaps) |
| `dump.git` | placement unconfirmed (dashboard check) | dockerfile | running:healthy | — |

A separate `docker-registry` project (service `registry`, image `registry:3`) predates the proven registry above; consolidate on one (see gaps). Edge API is rate-sensitive — space automated reads seconds apart; transient 404/string responses under burst load recover on retry.

## Secret escrow map (names only — values live in OpenBao, never in Git)

| OpenBao path | Fields | Consumers |
| --- | --- | --- |
| `secret/projects/ovhcloud/ADMIN_CLOUDFLARE` | `ADMIN_CLOUDFLARE` (API token) | Terraform loader, Cloudflare API automation |
| `secret/projects/ovhcloud/OVH_API` | `application_key`, `application_secret`, `consumer_key`, `endpoint` | `ovh_cli` read-only discovery |
| `secret/projects/ovhcloud/COOLIFY_TUNNEL_SECRET` | `tunnel_secret` | Terraform loader (preserved `coolify-admin` singleton) |
| `secret/projects/ovhcloud/COOLIFY_TUNNEL_<NAME>` | `tunnel_id`, `tunnel_token` | Per-target tunnel creation (fresh hosts) |
| `secret/projects/ovhcloud/COOLIFY_TUNNEL_TOKEN` | `tunnel_token` | Break-glass reinstall only (no automation reads it) |
| `secret/projects/ovhcloud/COOLIFY_R2` | `access_key_id`, `secret_access_key`, `bucket`, `endpoint` | Host-timer backup plane + restore probe |
| `secret/projects/ovhcloud/COOLIFY_ADMIN` | `app_key`, `email`, `password` | Coolify bootstrap and recovery |
| `secret/projects/ovhcloud/COOLIFY_API` | `token` (root-admin Sanctum) | API-driven app/resource creation + verification |
| `secret/projects/ovhcloud/COOLIFY_ACCESS_SERVICE_TOKEN` | `client_id`, `client_secret` | Machine edge access (noninteractive verification, API calls) |
| `secret/projects/ovhcloud/COOLIFY_SSH_PRIVATE_KEY` / `COOLIFY_SSH_PUBLIC_KEY` | key material | Guest bootstrap, Coolify machine connection |
| `secret/projects/ovhcloud/OMNIROUTE` | `STORAGE_ENCRYPTION_KEY`, `API_KEY_SECRET`, `JWT_SECRET` | OmniRoute apps (escrow-recoverable restore) |
| `secret/projects/ovhcloud/REGISTRY` | `htpasswd`, `http_secret`, `username`, `password` | Private registry auth + smoke verify (live 2026-09-17) |

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
7. OPEN 2026-09-17: `registry.pkubelka.cz` DNS + tunnel ingress were created via Cloudflare API outside Terraform state. Before the next `terraform apply`, import both (exact commands in `docs/09-docker-registry.md` §7) and require an empty plan — otherwise apply will fight live state.
8. OPEN 2026-09-17: consolidate the two registries (proven `registry:2.8.3` app in `omniroute` vs pre-existing `registry:3` service in `docker-registry` project) and triage `llm-quota2` (exited:unhealthy). Neither affects the proven registry path.

## Safety boundary (validated 2026-09-13)

No reconciliation ran `ovhcloud reinstall`, reboot, terminate, destroy, or credential rotation. Validation used only `ovhcloud vps list/get/ip list --output json`. The service remains `running`, so no recovery/reboot was needed. Terraform resources for the current VPS must be import/read-only or protected with lifecycle rules until a separately authorized replacement workflow exists.
