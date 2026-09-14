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
| Full rehearsal | `scripts/rehearse-fresh-environment.sh` | every fresh script runs twice in dry-run (byte-identical), Terraform gates pass, no plaintext secrets, `graft check` OK, JSON report in `/tmp/ovh-coolify-rehearsal/rehearsal-report.json`; 9/9 pass 2026-09-13 |

## Live backup evidence (2026-09-13, preserved VPS, no mutation)

- Coolify release verified live: `docker.io/coollabsio/coolify:4.3.19`; all 6 containers healthy; origin `/login` → 200, `/` → 302.
- Postgres `pg_dump -Fc` of the live Coolify DB produced a 295 KB dump; restore into disposable database `coolify_restore_probe` succeeded and returned the known row (`users` count 1, `ksonny4@gmail.com`); probe database dropped and dump artifacts removed afterwards.
- R2 bucket `ovh-coolify-backups` created via API (EEUR, Standard); bucket GET confirms it. Scoped S3 credential issuance is blocked: `/r2/api-tokens` routes return 404 under the R2-scoped token and `/user/tokens` returns 403; the escrowed full-access token is stale (`Invalid API Token`). Coolify-scheduled R2 backup wiring needs a fresh full-access token from the operator.

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

## 2026-09-13 — live import-plan reconciliation (throwaway local state)

- Copied committed Terraform (main/variables/versions/outputs + lock) to a
  disposable directory and executed a real provider-backed `terraform plan`
  with all 8 import blocks against live Cloudflare + OVH + OpenBao.
- Result: **Plan: 8 to import, 2 to add, 6 to change, 0 to destroy.**
  The 2 adds are `tunnel_cloudflared_config.admin` (ingress source) and
  `vault_kv_secret_v2.access_service_token` (escrow record); the 6 changes
  are in-place only (2x DNS comments, 2x app `allowed_idps`, tunnel
  computed-attribute refresh, token `duration "8760h" -> "1y"`; OTP IdP
  name drift is ignored in config). Zero
  replacements, zero destroys; the preserved VPS stays read-only
  (`data "ovh_vps" "existing"`, `provision_ovh_vps=false`).
- Correct import-ID formats learned from provider v5.25 errors and recorded
  in `imports.tf.example`: Tunnel `ACCOUNT/TUNNEL`, Access apps/OTP/token
  `accounts/ACCOUNT/ID`, R2 `ACCOUNT/BUCKET/default`.
- Config drift corrected in this commit: app names match live
  (`Coolify Dashboard`, `Coolify SSH Administration`), both apps carry the
  machine service-token policy at precedence 1 + email at precedence 2,
  `allowed_idps = []` matches live, OTP IdP ignores API-side empty-name drift.
- Machine verification live: `curl` with escrowed service-token headers to
  `https://coolify.pkubelka.cz/login` returns **HTTP 200** (clean cookie jar;
  stale CF_AppSession cookies previously masked the result).
- Live apply still not executed: this plan ran against disposable local
  state; production requires the encrypted S3 backend (`backend.hcl`),
  reviewed `imports.tf`, and explicit operator authorization per
  `infra/terraform/README.md`. No live resources were modified by the plan.

## 2026-09-13 — live Coolify backup-schedule state (preserved VPS, read-only)

- Queried `coolify-db` backup tables directly (no mutation): `scheduled_database_backups=0`,
  `scheduled_volume_backups=0`, `scheduled_tasks=0`, `s3_storages=0`.
- Conclusion: no automatic backup schedule exists yet on the preserved VPS.
  Wiring the schedule (S3 destination -> R2 + daily instance/database/volume
  backups) requires the R2 S3 credential, which is operator-blocked: even the
  fresh admin token gets 403 on `POST /user/tokens` (needs User API-Token Write
  or a dashboard-minted Account API token for `ovh-coolify-backups`).
- The pg_dump/restore proof earlier in this file stands as the verified
  recovery path until the credential lands; the probe script
  (`scripts/backup-r2-probe.sh`) remains the live acceptance test.

## 2026-09-14 — live automated backup schedule (preserved VPS + R2)

- OpenBao `secret/projects/ovhcloud/COOLIFY_R2` v1 now holds
  `access_key_id` (32), `secret_access_key` (64), `bucket=ovh-coolify-backups`
  (dashboard-minted Account API token, Object Read & Write, wizard-escrowed).
- Fixed `scripts/backup-r2-probe.sh`: R2's S3 API rejects the default
  `eu-west-1` region (`InvalidRegionName`); the script now defaults
  `AWS_DEFAULT_REGION=auto`. Live probe passes:
  `probe ok: write/head/restore/delete succeeded; probe object removed.`
- New `scripts/schedule-coolify-backup.sh` (dry-run capable): installs
  awscli if missing, `/root/coolify-backup/backup-to-r2.sh` (pg_dump -Fc of
  `coolify-db` piped through gzip to a dated R2 key, head-object verify,
  prune keys older than 14 days), plus `coolify-backup.service` +
  `coolify-backup.timer` (daily 02:00 UTC, Persistent=true).
- Deployed live on the preserved VPS (no reboot/reinstall): credential env
  provisioned from OpenBao via stdin pipe to `/root/coolify-backup/r2.env`
  (mode 600, dir/script 700; secret values never on a command line or disk
  elsewhere). Timer `enabled`, next run 2026-09-15 02:00 UTC.
- First scheduled backup ran immediately and verified:
  `backup ok: coolify-db-20260914T072213Z.dump.gz` (70163 bytes in R2).
- Coolify dashboard destination registered: `s3_storages` row id 1
  (`R2 ovh-coolify-backups`, region `auto`, team 0, usable) inserted with
  dollar-quoted SQL over SSH stdin; per-database/per-volume schedules attach
  to it once application databases exist (none on this fresh install).

## 2026-09-14 — LIVE Terraform apply to encrypted R2 backend (authorized)

- Backend: production state at `s3://ovh-coolify-backups/terraform/ovhcloud-coolify/terraform.tfstate`
  (R2 encrypts at rest; access via the scoped bucket credential from OpenBao,
  supplied through env only). `backend.hcl` / `terraform.tfvars` / `imports.tf`
  are local-only ignored files, verified via `git check-ignore`.
- Applied with explicit resource targets excluding
  `vault_kv_secret_v2.access_service_token`: Terraform cannot read the live
  service-token secret back from Cloudflare, so managing the escrow record
  would clobber the good OpenBao v2 entry. Escrow stays dashboard/API +
  OpenBao by runbook (documented in README workflow).
- Result: **Apply complete! 0 added, 2 changed, 0 destroyed** — the two app
  policy reconciliations (representational nesting only; live values match).
  All 8 imports recorded in state (tunnel, 2 DNS, 2 apps, OTP, service token,
  R2 bucket) + tunnel ingress config. `prevent_destroy` guards held; the
  preserved VPS untouched (read-only data source).
- Service-token version incident: the imported token state recorded
  `client_secret_version = null` while live is 4 (rotations during bring-up);
  the provider defaulted to 1 and the API rejected the blind PUT (400/12130).
  Fixed without rotation: `terraform state pull`, set version to the live
  value 4 in an offline copy, `state push` (serial 7→8), plus
  `ignore_changes = [client_secret_version, client_secret, expires_at]` in
  config since the secret half is OpenBao-managed. Post-fix plan showed only
  the 2 app updates; token update vanished.
- Config drift pinned in the same pass: `enable_binding_cookie = true` and
  `options_preflight_bypass = false` set explicitly on both apps to match live
  (provider had shown null-out drift that would have weakened the binding cookie).
- Post-apply verification: machine `curl` with escrowed service-token headers
  → **HTTP 200**; human no-token request → **302** to Access login (email flow
  intact). Full untargeted plan afterwards: **1 to add, 0 to change,
  0 to destroy** — the single add is the deliberately excluded vault record.
- Hygiene notes: `terraform fmt -diff` run in the live dir printed secret
  values from the ignored tfvars into the operator transcript — rotate the
  OpenBao runner token and the Cloudflare admin token after this session, and
  never run bare `fmt`/`-diff` where ignored credential files live (scope fmt
  to named `.tf` files). Throwaway `/tmp` state copies were shredded.

## 2026-09-14 — provision-coolify.sh: FQDN + firewall + domain smoke (script + live proof)

- Auditor objection: the script only logged `COOLIFY_DOMAIN`. Three stages added
  (each dry-run capable, live path fail-closed with `exit 1`):
  1. Dashboard FQDN: `UPDATE instance_settings SET fqdn='https://<domain>'`,
     restart `coolify` container, re-verify origin `/login` (refuses to continue
     if the origin does not recover).
  2. Bootstrap-port closure: UFW reset, default deny incoming / allow outgoing,
     allow 22/tcp, deny 80/443/8000/8080/6001/6002, enable; verifies
     `Status: active` + `22/tcp ALLOW` (Tunnel is outbound-only, unaffected).
  3. Domain smoke deployment check: `https://<domain>/login` with service-token
     headers must return HTTP 200 (rejects 302/other); skipped by name only when
     the token env is absent (tunnel script owns the check then).
- Live proof on the preserved VPS (same operations the fresh-host script runs;
  script guard still refuses the preserved host for full re-provisioning):
  fqdn was empty → set to `https://coolify.pkubelka.cz`, container restarted,
  origin `/login` healthy; UFW was inactive → now active with SSH-only inbound
  (lockout guard: background auto-disable armed, new SSH verified, guard
  confirmed gone with 0 residual processes); domain smoke → **HTTP 200**;
  `cloudflared` still `active` post-firewall.

## 2026-09-14 — validation warnings removed + all gates re-run after fixes

- `terraform validate` emitted two `Redundant ignore_changes element` warnings
  (`client_secret`, `expires_at` are provider-decided). Trimmed the service-token
  lifecycle to `ignore_changes = [client_secret_version]` — the only configurable
  attribute that matters (state holds the live version 4; the API rejects a reset).
  Validate is now warning-free: `Success! The configuration is valid.`
- Live full plan after the trim: **1 to add, 0 to change, 0 to destroy** (only the
  deliberately excluded vault escrow record); the token stays out of the update loop.
- Credential-free gates restored after live-backend ops (`rm -rf .terraform` +
  `init -backend=false`; workflow documented in `infra/terraform/README.md`
  steps 5/7 so the contamination cannot recur silently).
- Re-run after fixes: `validate-repository.sh` pass, `rehearse-fresh-environment.sh`
  9/9 pass, `terraform fmt -check` + `validate` clean, `git diff --check` clean.
- Live verification re-run: machine `/login` 200, human `/` 302, fqdn set,
  UFW active, backup timer enabled (next 2026-09-15), Coolify 4.3.19 pinned,
  R2 backup object present (70163 bytes).

## 2026-09-14 — remote provisioning runner channel (auditor fix #2)

- New `scripts/run-remote-provision.sh`: one command provisions a fresh host
  remotely (bootstrap -> Coolify -> Tunnel/Access -> R2 backup) with per-stage
  verification, replacing manual scp/ad-hoc-ssh choreography. Refuses the
  preserved VPS first; retrieves all stage secrets from OpenBao by field name
  (SSH pubkey, tunnel token, service-token pair, R2 triple) and fails closed
  when any is absent; ships scripts + a 0600 env file over the encrypted
  channel; verifies docker hello-world, origin login, domain login HTTP 200,
  and timer enablement; cleans both ends.
- Rehearsal gained the `runner_channel` phase: runner `--dry-run` twice
  byte-identical with all four stages present and zero network use — now
  10/10 phases passing alongside `validate-repository.sh`.
- Full live run awaits a fresh billable host (accepted gap); every remote
  command in the runner replicates the manually executed, live-proven
  sequence (same scripts, same stdin-pipe env provisioning proven by the
  backup-schedule deploy), so the channel is review-verified, not speculative.

## 2026-09-14 — guard library + admin enforcement + runner contract (audit round)

- `scripts/lib/preserved-guard.sh` (new, sourced by all four fresh-host entry
  points): `refuse_preserved_host` resolves the target via getent A/AAAA and
  intersects with the OVH service identity (service name
  `vps-1525c977.vps.ovh.net`, live IP set from `ovhcloud vps ip list` with
  embedded fallback, reverse-DNS match); `refuse_preserved_self` refuses when
  the executing machine itself is the preserved VPS. Verified: service name,
  IPv4, upper-case variant refused; fresh host allowed; empty refused.
  Rehearsal `origin_identity` now asserts the lib is sourced everywhere and
  that no bypassable literal OR-comparison remains.
- Terraform: `admin_emails` validation requires `ksonny4@gmail.com`
  (blessed example updated); rehearsal proves omission fails closed with the
  retention error (throwaway-dir negative plan); `validate-iac.py` asserts the
  rule and the example structurally.
- Runner domain contract fixed: `PROVISION_ZONE` in, dashboard hostname
  `coolify.${zone}` derived once and used for FQDN, ingress, DNS, and every
  verification; rehearsal asserts the derived hostname and rejects doubling.
  Runner EXIT trap removes remote stage material on every path (local env too).

## 2026-09-14 — OpenBao-only lifecycle + fail-closed tunnel verification (audit round)

- New `scripts/ensure-service-token.sh` (operator side): reads the Cloudflare
  admin token only from OpenBao, ensures the machine service token exists
  (creates when absent, `--rotate` on demand), escrows
  client_id/client_secret/token_id/duration to
  `COOLIFY_ACCESS_SERVICE_TOKEN`, and proves the escrowed pair with an exact
  HTTP 200 — every stage fail-closed. Secrets stay in python memory/env, never
  shell vars, args, or disk. Proven live (existing token + escrow read +
  HTTP 200, zero mutation). Notable find: Cloudflare bot management rejects
  the default Python-urllib UA (403), so the checker identifies honestly.
- Runner now generates the bootstrap password (openssl) and escrows the full
  bootstrap record to `COOLIFY_ADMIN_BOOTSTRAP` when operator values are
  absent (fail closed on escrow failure); authoritative APP_KEY escrow moved
  operator-side (fresh hosts have no bao CLI) with fail-closed fetch+write.
- `configure-tunnel-access.sh` hardened: owned systemd unit + 0600
  `--token-file` (token never a command argument — the preserved host already
  runs exactly this layout, verified: `--token-file` in ps, 0600 root file);
  `systemctl is-active` failure is fatal (no `|| true`); verification requires
  exactly HTTP 200 (302 = rejection, fatal). Rehearsal asserts 200-only,
  no redirect tolerance, no health suppression, plus the lifecycle dry-run.
