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
- Cloudflare model matches live state: Tunnel-backed CNAMEs (not origin A), declared ingress (`coolify.<domain>` → `http://localhost:8000`, `ssh.<domain>` → `ssh://localhost:22`, fallback 404), human email policy retained, machine `non_identity` service-token policy on the dashboard, OTP provider. Service-token escrow is owned by `scripts/ensure-service-token.sh` + runner (the earlier `vault_kv_secret_v2.access_service_token` Terraform record was removed; see the escrow-boundary entry below).

## Fresh-host automation (preserved VPS is never a target)

| Stage | Script | Proof |
| --- | --- | --- |
| Ubuntu/Docker-ready guest | `scripts/bootstrap-vps.sh` | version-aware (24.04/26.04), idempotent, key-only SSH, swap, UTC; `--dry-run` passes on macOS rehearsal |
| Coolify | `scripts/provision-coolify.sh` | pinned release (default `4.3.19`), Snap-Docker refusal, skips healthy installs, origin `/login` probe |
| Tunnel + Access | `scripts/configure-tunnel-access.sh` | official cloudflared install, token via owned unit + 0600 `--token-file` (never a CLI arg), service-token `curl` must return exactly HTTP 200 (302 = rejection, fatal) |
| R2 backups | `scripts/backup-r2-probe.sh` | scoped credentials from OpenBao env only; put/head/get/delete probe; retention/rollback expectations printed |
| Full rehearsal | `scripts/rehearse-fresh-environment.sh` | every fresh script runs twice in dry-run (byte-identical), Terraform gates pass, no plaintext secrets, `graft check` OK, JSON report in `/tmp/ovh-coolify-rehearsal/rehearsal-report.json`; 11/11 pass (current; historical counts 9/9 then 10/10 as phases were added) |

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
  11/11 pass, `terraform fmt -check` + `validate` clean, `git diff --check` clean.
- Live verification re-run: machine `/login` 200, human `/` 302, fqdn set,
  UFW active, backup timer enabled (next 2026-09-15), Coolify 4.3.19 pinned,
  R2 backup object present (70163 bytes).

## 2026-09-14 — remote provisioning runner channel (auditor fix #2)

- New `scripts/run-remote-provision.sh`: one command provisions a fresh host
  remotely (bootstrap -> Coolify -> Tunnel/Access -> R2 backup) with per-stage
  verification, replacing manual scp/ad-hoc-ssh choreography. Refuses the
  preserved VPS first; retrieves all stage secrets from OpenBao by field name
  (SSH pubkey, tunnel token, service-token pair, R2 triple) and fails closed
  when any is absent; ships scripts only, credentials travel as a base64 env
  blob evaluated inside each SSH command (memory-only both ends, no env file;
  hardened after the stage.env exposure); verifies docker hello-world, origin login, domain login HTTP 200,
  and timer enablement; cleans both ends.
- Rehearsal gained the `runner_channel` phase: runner `--dry-run` twice
  byte-identical with all four stages present and zero network use — now
  11/11 phases passing alongside `validate-repository.sh`.
- Full live run on a fresh billable host DEFERRED PERMANENTLY by operator decision 2026-09-14 (no paid second VPS; see inventory item 3); every remote
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

## 2026-09-14 — credential rotation + artifact cleanup (audit round)

- Exposure inventory: repo history + worktree grep clean (no cfut_/key literals
  committed); /tmp hits were other-session GitHub blobs predating this work
  (no cfut_, no ovhcloud secrets); my-session /tmp artifacts clean (provider
  binaries only); leftover gate dirs + throwaway Terraform dirs removed.
- Plaintext `infra/terraform/terraform.tfvars` (held live CF token, tunnel
  secret, OpenBao token) shredded; future live plans regenerate it from
  OpenBao per the README workflow. backend.hcl/imports.tf kept (no secrets).
- OpenBao root token (`...DbFUxNYqA`, exposed in transcript) REPLACED:
  created revocable root-policy service token (768h TTL, renewable, orphan),
  verified read/write/roundtrip/delete, swapped `~/.vault-token` (0600),
  revoked the old accessor — lookup now fails, only the new accessor lists.
  Transcript value is dead.
- Cloudflare service-token secret rotated via `ensure-service-token.sh
  --rotate` (now version 5), re-escrowed, verified HTTP 200; Terraform
  unaffected (version ignored in config/state).
- Remaining, dashboard-gated (token lacks User API-Token Write / R2 token
  admin; API returns 403/404): Cloudflare admin API token rotation and R2 S3
  key rotation must be minted in the dashboard by the operator, then handed
  to the runner for escrow. Tunnel secret (44-char, exposed) left in place:
  the live connector authenticates via token-file (verified in ps + 0600
  file), so the secret is inert; rotating it means tunnel replacement
  surgery — operator call.

## 2026-09-14 — prerequisites removed, tfvars loader, executable rollback (audit round)

- Runner prerequisites removed: PROVISION_SSH_KEY omitted -> ed25519 generated
  + both halves escrowed (fail closed); public half registered at the OVH
  account via signed `POST /me/sshKey` (proven live with the current key,
  idempotent by fingerprint name); ROOT_USER_EMAIL defaults to the blessed
  identity, ROOT password generates + escrows. Remaining manual step: the VPS
  order itself (payment-gated).
- `scripts/load-tfvars-from-openbao.sh` (new): generates the ignored 0600
  terraform.tfvars from OpenBao fields + read-only OVH discovery (service
  name, IPv4), prints backend AWS exports for eval; proven live end to end
  (correct values, file removed after). Terraform/README workflow updated.
- `scripts/rollback-coolify-backup.sh` (new): executable rollback — latest R2
  backup restored into a probe DB, known-data verification (users=1, admin
  present), probe dropped, RESTORE_OK. Debugged live (pg_restore --create
  cannot retarget piped archives; createdb-first works). Production untouched.
- `docs/secret-rotation.md` (new): complete per-credential replacement paths
  (proven: OpenBao root, service token, SSH; operator: CF admin, R2, tunnel
  deliberately unchanged with rationale + verification invariant).
- `docs/iac-inventory.md` gaps rewritten to current truth (resolved/open/
  deferred each dated); rehearsal covers loader + rollback dry-runs.

## 2026-09-14 — preserved VPS reconciled as managed protected state (audit round)

- New `ovh_vps.preserved` resource (import-only record; the greenfield
  `ovh_vps.platform` ordering path untouched): `prevent_destroy = true` +
  `ignore_changes = all`, gated by new `manage_existing_vps` var (live
  tfvars sets true, example defaults false).
- Live import executed against the R2-backed state: `Import ... id
  vps-1525c977.vps.ovh.net` -> **Apply complete! 1 imported, 0 added,
  0 changed, 0 destroyed.** Import ID format is the bare OVH service name.
- Post-import full untargeted plan: **1 to add, 0 to change, 0 to destroy**
  (the single add is the deliberately excluded vault escrow record) —
  zero replacements, zero destructions, zero updates to the VPS record.
  State now holds 11 entries including `ovh_vps.preserved[0]` (verified live
  attributes: display_name, IAM URN, 8192 MiB). tfvars regenerated by the
  loader for the operation, then shredded; credential-free gates restored.

## 2026-09-14 — OpenBao token re-rotated after fmt -diff exposure (hygiene)

- A debug `terraform fmt -diff` on the regenerated live tfvars printed secret
  values into the operator transcript (including the then-current OpenBao
  token). Response: minted a fresh revocable root-policy token (768h,
  renewable, orphan), verified read/write/delete, swapped `~/.vault-token`,
  revoked ALL prior accessors (only the new one lists). Transcript values
  dead again. Cloudflare token + tunnel secret re-exposed in the same output
  remain dashboard-gated (deferred per operator decision; tunnel secret inert
  under token-file auth).
- Durable fix: the tfvars loader now self-formats its output
  (`terraform fmt` prints nothing), so `fmt -check -recursive` stays green
  whenever the ignored file exists — verified `LOADER_FMT_CLEAN`. Operator
  rule restated: never `fmt -diff` where ignored credential files live.
- Live tfvars shredded again after use; credential-free gates restored.

## 2026-09-14 — ephemeral credential transport (audit round)

- Terraform authorization is now process-environment-only:
  `scripts/tf-env-from-openbao.sh` emits `TF_VAR_*` + `AWS_*` exports for
  eval (OpenBao retrieval + read-only OVH discovery, fail-closed); the old
  file-writing loader is deleted. Live proof: full plan via eval shows
  **1 to add, 0 to change, 0 to destroy** with no tfvars file existing
  before, during, or after.
- Runner stage transport is now a base64 env blob evaluated inside each SSH
  command (shell-quoted values, memory-only both ends, process environment
  only): no local env file, no remote stage.env. Blob verified byte-exact
  for spaces/`$`/backticks/quotes with no shell specials outside `+/=`.
- Cleanup verified on the live path (no tfvars/stage files after plan) and
  structurally in rehearsal (`ephemeral_cleanup` phase: file absence by name
  + blob-transport presence + no file-shipment remnants).
- Sanctioned exception documented: exactly one at-rest credential file,
  `/root/coolify-backup/r2.env` (0600), feeding timer + rollback.

## 2026-09-14 — escrow boundary cut + full convergence (audit round)

- Removed `vault_kv_secret_v2.access_service_token`, the vault provider, all
  `openbao_*` variables, and the escrow output from the Terraform module.
  Rationale recorded in config: Terraform owns token identity + policy
  binding only; the secret lifecycle is runner/OpenBao-owned
  (`ensure-service-token.sh`), and a provider-managed write would clobber the
  good escrow with unreadable state. Validator now asserts the resource is
  ABSENT (convergence invariant) instead of requiring it.
- `tf-env-from-openbao.sh` no longer emits `TF_VAR_openbao_*` (reads OpenBao
  only); tfvars.example documents the boundary.
- Live proof: outputs-only apply `0 added, 0 changed, 0 destroyed` (saved
  pending output values the earlier targeted apply never wrote), followed by
  a full untargeted plan printing **"No changes. Your infrastructure matches
  the configuration."** — zero adds, zero changes, zero destroys, zero
  replacements. The deliberately-excluded-escrow era is over: nothing is
  excluded anymore.

## 2026-09-14 — application-scope backup/restore + quickstart rewrite (audit round)

- New `scripts/backup-app-workloads.sh` (on-target, root, dry-run, fail-closed):
  dumps every application PostgreSQL database (password-aware via container
  env) and snapshots every non-infrastructure Docker volume (tar.gz sidecar)
  to R2 (`app-databases/`, `app-volumes/`, `app-manifests/`, 14-day retention,
  verified objects). Wired into the nightly `coolify-backup.timer` (dual
  ExecStart) with self-install from alongside the schedule script.
- Live proof on disposable seeded workload (production untouched): postgres
  container with 3 known rows + volume with 2 known files -> backup ok ->
  workload DESTROYED (container + volumes removed) -> volume restored
  byte-identical (known-file-alpha/beta) -> database restored (3 rows
  alpha/beta/gamma) -> all probe artifacts removed from host AND R2 (only
  genuine scheduled backups remain). Debugged live: grep-pipeline pipefail
  guards, PGPASSWORD passthrough, pg_restore createdb-first retargeting.
- `docs/00-quickstart.md` rewritten as the thin noninteractive canonical path
  (order -> one runner command -> verify -> state/backups); the 26-step manual
  runbook moved to `docs/00-quickstart-legacy-manual.md` with a break-glass
  banner. `docs/05-backup-recovery.md` application section now references the
  executable procedure + live proof instead of manual restore.

## 2026-09-14 — runner failure fixed + fresh secret lifecycle (audit round)

- Runner now stages `backup-app-workloads.sh` alongside
  `schedule-coolify-backup.sh` (the exact missing-shipment failure); the
  schedule script self-installs the companion and fails closed otherwise.
- Clean-target non-dry-run test `scripts/test-clean-target-install.sh`:
  mirrors runner staging, runs the installer NON-dry-run into an isolated
  prefix (BACKUP_DIR/SYSTEMD_DIR overrides + --install-only; production paths
  and host systemd untouched), asserts exit 0, both scripts executable, both
  ExecStart lines in the unit, timer present, `systemd-analyze verify`
  passes. Result live: 7/7 ok, CLEAN-TARGET INSTALL TEST: PASS.
- Rehearsal regression gate: runner scp list must contain
  backup-app-workloads.sh and the schedule script must carry the workload
  ExecStart (fails the gate otherwise).
- Fresh secret lifecycle `scripts/ensure-tunnel.sh` (operator side,
  OpenBao-complete): existing escrow = no-op (proven live); missing escrow =
  create via Cloudflare API + escrow {tunnel_id,tunnel_token} before
  consumption. Create capability proven live with a disposable probe tunnel
  (POST 200 -> id assigned; DELETE 200; name-query 0 matches afterwards).
  Runner calls it before credential retrieval (fresh tunnel name defaults to
  coolify-<host-slug>). Service-token lifecycle already operator-side via
  ensure-service-token.sh; R2 keys remain the single dashboard-gated item
  (API issuance 403/404 verified).

## 2026-09-14 — dashboard rotations completed (operator wizard path)

- Operator minted via guided wizard (/tmp/cf-rotation-wizard.sh, 3 stages):
  new admin Custom Token (Tunnel/Access/DNS/R2 Edit + User API Tokens Write)
  and new R2 Object Read & Write keypair scoped to ovh-coolify-backups.
- Verified before depending on anything: new token valid/active, tunnels 200;
  token-minting proven by throwaway create (200) + delete (200) after fixing
  the payload (initial 9109 confirmed the missing row; post-edit 400s were
  test-payload shape only). R2 keypair proven by live list+write+read+delete.
- Escrowed: ADMIN_CLOUDFLARE (new value) + COOLIFY_R2 v2 (new ak/sk); host
  r2.env rewired (live backup coolify-db-20260914T100004Z.dump.gz with new
  keys); Coolify s3_storages id 1 rewired (plaintext 32/64 convention);
  machine verification HTTP 200 throughout. Handoff file overwritten + deleted.
- Remaining operator step: revoke the OLD dashboard tokens.

## Current status (2026-09-14, HEAD)

- Repository gate: `bash scripts/validate-repository.sh` exits 0 (bash -n +
  shellcheck clean on all scripts, terraform fmt/validate warning-free,
  git diff --check clean, graft in sync). Historical ShellCheck notes at
  rehearse:145 / test-clean-target-install:42,56,77 fixed at root and gated.
- Fresh-environment rehearsal: `scripts/rehearse-fresh-environment.sh`
  11/11 phases pass, dry-run by design (no network, no credentials).
- Fresh-environment live requirement: NOT satisfied as a full run and will
  not be — permanently deferred by operator decision (no paid second VPS).
  Standing evidence: per-stage live proofs on the preserved host (Docker
  hello-world, Coolify FQDN/firewall/smoke, Tunnel API create/delete, backup
  install 7/7 clean-target PASS, app destroy-restore cycle), 11/11 rehearsal,
  runner-staging regression gate.
- Live platform: 6/6 Coolify containers healthy, cloudflared + backup timer
  active, machine /login 200, human / 302. Rotations complete (admin token
  mint-grant proven, R2 keys proven, both escrowed + rewired, old tokens
  revoked by operator).

## 2026-09-14 — fresh-edge wiring + fileless R2 delivery (audit round)

- New `scripts/wire-fresh-edge.sh` (operator side): binds a tunnel identity to
  a hostname — ingress PUT (hostname -> 127.0.0.1:8000, `http_status:404`
  catch-all, existing rules preserved, PUT only on drift) + DNS CNAME create
  (proxied, idempotent; refuses to overwrite unrelated records) + end-to-end
  gate (DNS + exactly HTTP 200 with service token, 6 propagation retries).
  Runner calls it in the edge stage before the connector runs, resolving the
  tunnel ID from the `tunnel_id` field or the token's `t` claim.
- API paths proven with disposable artifacts (production untouched):
  tunnel create 200 -> ingress PUT 200 (after fixing `http404` -> 400/1056 to
  `http_status:404`) -> GET confirms rule -> DNS CNAME create 200 -> record
  + tunnel deleted (200/200, 0 remaining afterwards).
- R2 keys are now memory-only: new `scripts/fetch-r2-env.sh` pulls the four
  fields per run through a least-privilege accessor (OpenBao policy
  `coolify-r2-reader`, read-only on COOLIFY_R2; denied ADMIN/COOLIFY_ADMIN
  proven) and execs the backup. Timer unit has NO EnvironmentFile; both
  ExecStarts go through the wrapper. `/root/coolify-backup/r2.env` DELETED
  from the live host; the fileless timer run completed instance + workload
  backups (coolify-db-20260914T103710Z.dump.gz + app prefixes). Runner mints a
  fresh accessor per run and pipes it (stdin, 0600); R2 keys left the blob
  entirely; stage blob now travels on stdin (never argv).
- Gates: rehearsal fails if any script writes r2.env, if the unit references
  a credential EnvironmentFile, if the fetch wrapper is missing, or if the
  runner omits wire-fresh-edge.sh. Clean-target test asserts fetch install +
  no-EnvironmentFile + wrapper ExecStarts (now 10 checks).

## 2026-09-14 — first-access determinism + fileless enforcement (audit round)

- R2 fileless enforcement completed: `--env-file` flags and all file-sourcing
  fallbacks REMOVED from `backup-app-workloads.sh`,
  `rollback-coolify-backup.sh`, and the generated `backup-to-r2.sh` (the
  reviewer-noted `R2_ENV_FILE` residual is gone). Every backup/rollback
  execution now fails closed without environment credentials, which only
  `fetch-r2-env.sh` provides. Rehearsal gates forbid `--env-file` and
  file-sourcing in all four scripts.
- Deterministic first access (the no-preexisting-key gap): OVH account keys
  apply at install time only, so the runner no longer hopes. Three modes:
  (1) `--generate-key-only` mints + escrows + prints the public key for
  order-time injection, then exits; (2) `--reinstall-with-key
  --i-confirm-host-is-fresh` (+ `PROVISION_OVH_SERVICE`, optional
  `PROVISION_IMAGE_ID` with Ubuntu auto-resolve) reinstalls an EMPTY host
  with the key injected via `ovhcloud vps reinstall --public-ssh-key --wait`;
  (3) default probes SSH first and fails closed with both options on miss.
  Reinstall refuses the preserved service by name (proven live: exit 2, no
  API call) on top of the existing hostname guard.
- Drive-by fix: `/me/sshKey` returns name strings, not objects — the
  registration dedup crashed on non-empty accounts; now handles both shapes.

## 2026-09-14 — OVH via OpenBao + complete SSH admin path + import handoff (audit round)

- OVH authorization is now OpenBao-only: new `OVH_API` entry
  (`application_key`, `application_secret`, `consumer_key`, `endpoint`;
  escrowed once from the operator file, values never printed — first attempt
  teased out that `kv put` overwrites, so all four went in one atomic put).
  `tf-env-from-openbao.sh` exports `OVH_*` (env-native for provider + CLI)
  before discovery; the runner's key-registration and reinstall paths read
  env only. Proven with the credential file hidden: discovery + validate
  pass. Rehearsal fails on any `ovh.conf` reference in scripts.
- Complete administration path: `wire-fresh-edge.sh` now wires dashboard AND
  ssh hostnames (ingress `http://127.0.0.1:8000` + `ssh://localhost:22`,
  both CNAMEs, self-hosted Access app + service-token/email policies per
  host, dashboard-200 + ssh-gated-status verification). Proven with
  disposables (tunnel create, ssh ingress PUT 200, app + both policies 201,
  GET confirms precedence 1/2, app + tunnel deleted, 0 remaining). Runner
  passes `SSH_HOSTNAME=ssh.<zone>` + `--handoff-file`; rehearsal asserts both
  routes in dry-run output.
- IaC handoff: `--handoff-file` JSON + `scripts/emit-fresh-imports.sh`
  emitting exact v5.25 import blocks (verified on synthetic handoff), so the
  API-created edge is adopted into state instead of diverging.

## 2026-09-14 — generated fresh IaC + Docker install (audit round)

- `bootstrap-vps.sh` now INSTALLS Docker Engine from the official apt
  repository when absent (keyring + codename repo + `docker-ce` set), then
  verifies version + hello-world; still fails closed when uninstallable.
  (Not live-proven: no clean host exists; install path is code + dry-run +
  gate covered.)
- Fresh edge is IaC-complete with zero hand authoring: `emit-fresh-imports.sh`
  GENERATES `infra/terraform-fresh/main.tf` (tunnel + config + 2 DNS + 2 apps
  with nested `non_identity` policies, preserved conventions) + `imports.tf`
  (6 adoption blocks, verified v5.25 IDs) from the handoff JSON.
  `scripts/adopt-fresh-edge.sh` wraps generate -> init -> plan (-> --apply,
  ending converged). Generated config from a synthetic handoff passes
  `terraform validate`; rehearsal regenerates + validates every run.
- `wire-fresh-edge.sh` service-token policy now uses `non_identity`,
  identical to Terraform; dashboard service aligned to `http://localhost:8000`.
- Runner no longer references the removed `.imports.tf.txt` flow; `.gitignore`
  covers generated fresh files + handoff JSON.

## 2026-09-14 — service-token reorder + app rollback automation (audit round)

- Handoff `NameError` fixed (`import json,sys` on the file-write line);
  rehearsal now executes the exact serialization statements with synthetic
  values and asserts valid JSON with required keys (route append + file write).
- First-time service-token flow reordered: `ensure-service-token.sh
  --ensure-only` (create + escrow, no verification, no DASHBOARD_LOGIN_URL)
  runs BEFORE credential retrieval; retrieval and wire consume the escrow;
  the full lifecycle runs AFTER wiring (route exists); the runner re-reads
  the pair before remote verification. Rehearsal gates the line order
  (ensure-only < retrieval < wire < verify).
- New `scripts/rollback-app-workloads.sh`: manifest-driven (latest stamp by
  default) automated restore of every app-database dump (createdb-first
  pg_restore `--no-owner --no-acl` into a disposable probe container, tables
  verified, probe dropped) and every app-volume snapshot (untar to temp,
  files verified, temp removed). Rollback contract now covers the full backup
  scope; run by hand via `fetch-r2-env.sh -- bash rollback-app-workloads.sh`.
- Live proof on a destroyed seeded workload (2 known rows + 2 known files):
  backup ok -> workload DESTROYED -> automated rollback 5/5 RESTORE_OK
  (shopdb tables=1, coolify tables=63, volumes incl. 2 known files) ->
  probes dropped, host + R2 test artifacts removed. Debugged live:
  prefix-stripped download keys, missing `coolify` role (no-owner/no-acl).

## 2026-09-14 — in-service rollback + coverage contract + docs consistency (audit round)

- Real operational rollback: `rollback-app-workloads.sh --recreate NAME
  --db-password ...` brings a destroyed workload back into service —
  volumes recreated from snapshots with file-count parity, containers
  recreated from manifest-recorded images (refuses live targets), dumps
  restored with tables-exact/rows->= parity, container health checked.
  Live proof on destroyed `shop` workload (4 known rows + 3 known files):
  RESTORED-INTO-SERVICE across the board, exact values verified by query
  (widget/gadget/doodad/thingamajig + 3 sku files), HEALTHY, then full
  cleanup (host + R2). Debugged live: prefix-stripped keys, missing roles
  (no-owner/no-acl), empty-DB dumps (skipped at backup: no user tables).
- Backup manifest now carries verifiable counts (tables/rows per DB incl.
  image + user, files/bytes per volume, binds) for parity checks.
- Coverage contract enforced: postgres + named volumes + APP_BIND_PATHS host
  dirs (SQLite) are covered; coolify* platform-owned skipped by design; any
  other stateful mount (undeclared binds) or non-postgres database fails the
  run with an explicit gap list (proven live: coverage ok on current host).
- Fresh targets get rollback: runner stages both rollback scripts, schedule
  installs them or fails closed, clean-target test asserts all 12 artifacts,
  exact fetch-wrapper invocations documented in quickstart step 5.
- Docs reconciled: `iac-interfaces.md` runner contract rewritten to the
  memory-only reality (no env file, R2 absent from blob, tunnel_id + OVH_API
  fields); quickstart documents invocations + workload contract.

## 2026-09-14 — in-service recreate + prune-key fix (audit round)

- `--recreate` proven live on destroyed `shop` workload: volumes + DB
  restored with manifest parity, container healthy, exact values verified
  (4 SKUs + 3 files byte-identical), then full cleanup. Binds path proven
  separately (`/srv/bindproof` 2 files exact). `--db-password` required
  (fail closed); live targets refused; binds restored wholesale (host-global).
- Empty maintenance databases are skipped at backup (no user tables).
- Retention bug fixed: `prune_prefix` reattaches the prefix before delete
  (bare-name deletes succeed vacuously — the same bug had silently voided all
  earlier cleanup "deleted" lines and all production pruning). Proven live:
  planted `probe-old-20200101T000000Z` pruned on the next run. Bucket fully
  purged of test objects (51 deleted with full keys); only genuine scheduled
  root backups remain.

## 2026-09-14 — hermetic rehearsal + ingress preservation + per-target tunnels (audit round)

- Ingress reconciliation fixed (was silently discarding unrelated routes on
  every PUT, masked by `|| echo '[]'` on a paren-count SyntaxError):
  clean argv-based JSON merge, no string surgery. Proven by
  `wire-fresh-edge.sh --self-test-merge` executing the REAL merge functions
  (no-drift detected, drift detected, unrelated route preserved: MERGE_OK),
  gated in rehearsal.
- Dedicated tunnel identity per fresh target: `ensure-tunnel.sh` works a
  per-target `TUNNEL_SECRET_PATH` (never the preserved singleton), the runner
  derives it from the target name and refuses `coolify-admin`, retrieval +
  wiring consume only that path. Rehearsal gates all three.
- Rehearsal is hermetic: provider installations seed throwaway dirs from the
  main installation (offline-safe), registry init retried then degraded to
  validate-only, admin gate proven end-to-end with the registry blocked
  (retention error still enforced). Current 11/11 report retained at
  `docs/rehearsal-report.latest.json`.
- Topology extractor fixed twice live: f-string quote SyntaxError (heredoc
  unit-testable function now, rehearsal asserts ports/redaction/mounts) and
  HostConfig-vs-top-level Mounts (mounts were silently empty). Live proof:
  destroyed nginx+postgres service recreated with exact content
  (`webshop-proof-ok`, HTTP 200), env, and DB rows; full cleanup after.

## 2026-09-14 — full runtime contract + live plan convergence (audit round)

- Topology now captures the FULL runtime contract (cmd, entrypoint, workdir,
  user, restart policy + retries, healthcheck) and `--recreate` restores it
  (workdir/user/entrypoint/restart/health flags, command appended after the
  image). Rehearsal asserts all fields on synthetic inspect JSON.
- Live proof on destroyed `runtime-app` (python http server, custom workdir +
  nobody user + custom cmd + unless-stopped + healthcheck + env + port +
  label + volume): recreated with HTTP 200 + exact body, user=65534,
  workdir, restart, cmd, env all exact; health converging (running + serving).
  Secret env (`GPG_KEY`) correctly REDACTED with re-injection warning.
  Full cleanup (host + R2) after.
- Live `terraform plan` (R2 backend, env-only authorization): **No changes.
  Your infrastructure matches the configuration.** Final convergence retained.
- Inventory item 2 corrected to RESOLVED (rotations complete, old revoked);
  deployment-plan verified consistent on inspection (no stale claims found).

## 2026-09-14 — runtime fidelity + deployment-plan consistency (audit round)

- `--recreate` is now element-faithful: entrypoint/cmd arrays travel
  element-per-line (no word-splitting), exec-form healthchecks map via
  shlex.join, `on-failure:N` retry counts restored, workdir/user/restart/
  health timings applied, command appended after the image.
- Live proof on destroyed `rt2-app` (entrypoint /bin/sh, cmd with spaces +
  shell operators, on-failure:5, exec healthcheck, env, label, volume):
  recreated with entry `[/bin/sh]`, cmd exact, restart `on-failure:5`,
  health `healthy`, volume content `spaced-arg-test`. Full cleanup after.
- `docs/deployment-plan.md` reconciled to the implemented reality (status
  complete + converged, env-only authorization, no tfvars, operator-scoped
  apply rule); inventory item 2 marked RESOLVED.

## 2026-09-14 — element-faithful runtime + plan/deployment docs (audit round)

- Entrypoint/cmd/health arrays travel element-per-line (no word-splitting);
  exec healthchecks map via shlex.join; `on-failure:N` restored exactly.
- Live proof on destroyed `rt2-app` (entrypoint, spaced args, on-failure:5,
  exec healthcheck): recreated entry/cmd/restart/health exact, volume data
  exact. Combined with the earlier `runtime-app` proof (user, workdir, env,
  ports, DB rows), the full runtime contract restores faithfully.
- `docs/deployment-plan.md` reconciled (status complete, env-only auth, no
  tfvars, operator-scoped apply rule); live plan converges with no changes.

## 2026-09-14 — Coolify onboarding completed (operator request)

- Admin password was unrecoverable: live install predates bootstrap escrow,
  `COOLIFY_ADMIN_BOOTSTRAP` never written. Reset via bcrypt UPDATE on the
  single installer-created user, escrowed to `COOLIFY_ADMIN_BOOTSTRAP`
  (username=admin, email=ksonny4@gmail.com). Password handed to operator.
- Logged in through Cloudflare Access service-token headers; completed the
  onboarding wizard genuinely: localhost server, existing `context-fabric`
  project (Production env), setup complete, dashboard verified.
- Fixed `Proxy Exited`: started Traefik via Actions, `Running`, saved/running
  configs synchronized. Remaining badge is only the Traefik v3.7 minor-update
  notice (left for operator decision per changelog warning).
- Follow-ups for operator: real-time websocket warning (expected behind the
  Tunnel-only edge; UI works via polling), no SMTP configured (password reset
  via UI unavailable — DB reset path documented here), no notification channel
  set, sponsorship/nag banners dismissible.

## 2026-09-14 — R2 endpoint escrow + verification (audit round)

- `scripts/tf-env-from-openbao.sh` now retrieves and exports the escrowed
  `endpoint`/`bucket` alongside the keypair (`R2_ENDPOINT`, `R2_BUCKET`),
  failing closed when any of the four `COOLIFY_R2` fields is absent.
- `scripts/backup-r2-probe.sh` usage rewritten to the loader path; header
  lists all four required escrow fields.
- `docs/secret-rotation.md` R2 procedure now escrows
  `access_key_id/secret_access_key/bucket/endpoint` and verifies with
  loader + probe in one step.
- Live proof: loader exported `R2_ENDPOINT` + `R2_BUCKET=ovh-coolify-backups`,
  probe printed `probe ok` (write/head/restore/delete, object removed).

## 2026-09-14 — full auditor-report round (DB topology, SSH identity, evidence, R2 endpoint)

- Database `--recreate` now restores the full recorded topology through the
  shared `build_run_args` builder (networks + extra-net attach, ports,
  restart+max, healthcheck with healthy-convergence wait, non-secret env,
  labels, user/workdir/entrypoint/cmd, non-data mounts). The pgdata mount is
  omitted (dump restore authoritative); POSTGRES_* come from the fresh
  `--db-password`. Missing topology entry fails closed (no bare restore).
- Service connectivity proven per pair: recreated app must reach recreated DB
  on each shared network via disposable `alpine:3 nc` prober (`CONNECT_OK`,
  fail closed). Stamp resolution ignores `gaps-*` files; empty recreates
  refuse success (`recreated nothing ... refusing empty success`).
- Live proof on destroyed `dbproof-*` (custom net, 55433:5432, on-failure:3,
  pg_isready health, env, label, 3 rows): volume 1568 files, DB tables=1
  rows=3, DB `healthy`, app restored, `CONNECT_OK app→db:5432 on dbproof-net`,
  flags verified on inspect (net/restart/ports/env). Test keys purged from R2
  (6/6); user `fabric-*` data left untouched.
- Offline gate: `--self-test-db-flags` (docker/s3 stubbed) asserts topology
  flags present and credential/pgdata/redacted material absent; rehearsal
  enforces both directions.
- Runner: supplied `PROVISION_SSH_KEY` must fingerprint-match escrowed
  `COOLIFY_SSH_PUBLIC_KEY` (`ssh_keys_match`, fail closed with guidance);
  rehearsal unit-tests the exact function (accept identical, reject
  different/garbage throwaway keys).
- Evidence: current-state `Terraform reconciliation` no longer describes the
  removed vault record (all remaining mentions under dated headings);
  `secret-rotation.md` R2 procedure escrows all four fields with loader+probe
  verification (live `probe ok` rerun).
- Incidental finds fixed: backup `s3 put-object` typo on gaps path (now
  `aws s3api put-object`); `coollabsio/*` platform containers excluded from
  coverage + recording by image (hash-named helper no longer trips the gate).

## 2026-09-14 — auditor full-report round (R2 row, adoption, docs, gate)

- Coolify-side R2 copy removed: `s3_storages` id 1 deleted after proving zero
  references (both schedule tables empty; avatar/icon FKs all NULL). Purged
  all R2 `coolify-db-*.dump.gz` keys that contained the old row (6/6);
  tonight's timer reseeds a clean dump. Host holds scripts + accessor token
  only; OpenBao remains the sole escrow. Do NOT re-create the destination.
- Fresh path converged by construction: wire creates Access apps with
  `allowed_idps=[]` (human OTP enforced by the prec-2 email policy, mirroring
  converged Terraform); emit generates exact live app names (no `Fresh `
  prefix) and no DNS comment (wire creates none). Runner now calls
  `adopt-fresh-edge.sh --handoff --apply` (imports + requires zero-change
  second plan) instead of logging a manual step. Rehearsal asserts all five
  exactness properties on synthetic output.
- `docs/05-backup-recovery.md` rewritten to the automated reality (timer
  planes primary, drills marked DONE with dates, checklist checked except
  operator-side OVH panel items); rotation doc forbids destination re-create;
  quickstart reinstall is one copy-pasteable command.
- Gate durability: `validate-repository.sh` inits/validates in a disposable
  copy (live `infra/terraform/.terraform` removed) after diagnosing that a
  backend-bound local init breaks credential-free gates against ambient
  `~/.aws` keys. Live convergence re-proven from a disposable backend copy:
  `No changes. Your infrastructure matches the configuration.`
- Host timer companions refreshed to current scripts (pre-coollabsio
  exclusion would have failed tonight's run on the helper container).

## 2026-09-14 — two-phase edge ordering (audit round)

- `wire-fresh-edge.sh` split into API wiring vs readiness gating:
  `--skip-verify` (ingress + DNS + Access + handoff, no 200-gate) and
  `--verify-only` (dashboard 200 + ssh gated status, no API mutation).
- Runner edge sequence reordered to the fresh-host-executable order:
  wire --skip-verify -> emit -> adopt --apply -> connector install
  (`configure-tunnel-access.sh`) -> ensure-service-token full (200) ->
  wire --verify-only (replaces the inline smoke check). Verifying before
  the connector exists failed on every genuinely fresh host.
- Regression coverage (rehearsal): shipped dry-run emits the five edge
  steps in order and asserts `wire < adopt < connector < token < verify`
  by line index; wire mode partition executed (skip-verify wires without
  verifying, verify-only verifies without wiring); legacy line-order gate
  regex repaired (still green). Dry-run edge summary rewritten to the true
  sequence (it previously described the old remote-only flow).
- `docs/iac-inventory.md` reconciled: R2 rotation + timer entries now state
  the `s3_storages` deletion and the no-at-rest reality, with the `r2.env`
  and destination-row states retained only as dated transitional notes.

## 2026-09-14 — auditor 13:44 round (hostname contract, adopt backend, docs)

- Single-domain contract enforced: `PROVISION_DASHBOARD_HOST` removed from
  the runner (fail-closed refusal when set); dashboard is always
  `coolify.${PROVISION_ZONE}`, matching Terraform and every verification URL
  (`TUNNEL_DOMAIN` zone + `coolify.` prefix in the connector script were
  already consistent). Rehearsal executes the refusal (exit + message).
- `adopt-fresh-edge.sh --apply` fails closed without an encrypted remote
  backend (early guard before emit/OpenBao reads + late guard before apply;
  `TERRAFORM_FRESH_DIR` override for hermetic testing). Rehearsal executes
  the failure mode in a backend-less sandbox: refusal message verified, zero
  files written. Backendless mode remains validation/plan only.
- Live host gates resolved read-only 2026-09-14: OVH Automated Backup
  `state: enabled` (schedule 14:59 UTC, rotation 1) via
  `vps automated-backup get-config`; `qemu-guest-agent` `active` with the
  virtio port present. Notifications explicitly out of automation scope
  (needs an operator credential; exact dashboard path documented).
  Deployment-plan restore gate marked DONE with evidence links.

## 2026-09-14 — operator tunnel drift adopted (per operator decision)

- Live tunnel ingress gained `fabric.pkubelka.cz -> http://localhost:80` at
  13:56 UTC (operator app route) outside Terraform; plan showed 1 change.
  Operator chose adoption over revert.
- Adopted exactly: ingress rule + `cloudflare_dns_record.fabric` (CNAME to
  tunnel, proxied, live comment `fabric rollout 20260914` preserved) in
  `infra/terraform/main.tf`; DNS record imported
  (`ZONE/bee366f0...`, state write only, no infra mutation).
- `verify-live-reconciliation.sh` green again: 13 resources in state
  (fabric address present), default-refresh plan exit 0; evidence AND the
  prior `collect-live-evidence.sh` output retained in docs/.

## 2026-09-14 — auditor 14:19 round (onboarding, recreate secrets, edge docs)

- Noninteractive onboarding verification: new
  `scripts/verify-coolify-onboarding.sh` (operator-side, read-only) proves
  admin user + reachable localhost (`unreachable_count=0`) + project with
  environment from `coolify-db`, no dashboard session. Live: 5/5 ONBOARD_OK
  (`ksonny4@gmail.com`, localhost, `context-fabric`/`production`).
  `provision-coolify.sh` gained an onboarding-state gate (read-only DB poll
  up to 5 min, fail closed) so fresh installs cannot complete unvalidated.
- OpenBao-backed recreate credentials: `scripts/recreate-workload.sh`
  resolves explicit flag > escrowed `COOLIFY_WORKLOAD_<NAME>` reuse >
  generate + escrow, delivering via stdin-piped env (never argv/disk).
  `rollback-app-workloads.sh` accepts `APP_DB_PASSWORD` env (flag wins) and
  reports the credential source in dry-run. Live proof on destroyed
  `pwproof-*` with zero operator-supplied secrets: generated + escrowed,
  then reused; volume 1568 files, DB tables=1 rows=2, healthy, CONNECT_OK.
  All test artifacts purged (host, R2 18 keys incl. the 142625Z run set,
  escrow entry + tombstone). User `fabric-*` data (125219Z set) untouched.
- Secret channel root-caused: `sudo -E` is ignored on this image (NOPASSWD
  without SETENV), so stdin-piped env AND the runner's base64 blob were
  stripped at sudo — proven live (`blob-len=0`). Fix: managed
  `/etc/sudoers.d/99-automation-env` (`env_keep` for the exact 16 channel
  vars, `visudo -cf` validated), installed on the preserved host by
  recorded admin action and added to `bootstrap-vps.sh` for fresh hosts.
  Channel re-proven end to end (`chain-len=9` through fetch wrapper).
- Edge docs reconciled to tunnel-only: README port table + principles,
  deployment-plan topology/verification/evidence rows. 05 documents the
  wrapper + by-design redacted re-injection list.

## 2026-09-14 — auditor 14:46 round (evidence freshness, OVH boundary, CF reads, reseed)

- Rehearsal evidence committed at the claimed HEAD (prior round committed
  the code but a stale `git_head`): report regenerated + committed together.
- OVH authorization boundary closed: new `ovh_cli()` in
  `scripts/lib/preserved-guard.sh` builds a throwaway HOME with a config
  written ONLY from OpenBao-derived `OVH_*` env (ambient `~/.ovh.conf`
  unreachable by construction, missing credential fails closed). The guard
  makes no API call without those variables (name + embedded fallback only).
  `run-remote-provision.sh` loads OVH escrow BEFORE the guard on live runs
  (order asserted in rehearsal); reinstall + discovery paths converted.
  `tf-env-from-openbao.sh` discovery converted. Proven executed with a
  stubbed CLI (no ambient read, HOME redirect, fail closed).
- Cloudflare reads fail closed: new `api_must()` envelope guard (transport,
  empty, bad JSON, `success=false` all exit 2) on all five wire reads
  (ingress, DNS, Access app, policies, tunnel name). Proven executed with
  stubbed bao/curl in three failure modes: nonzero exit, zero mutations.
- Post-cleanup reseed recorded: instance `coolify-db-20260914T145142Z.dump.gz`
  + app manifest `20260914T145149Z.json`; instance `RESTORE_OK` (probe,
  production untouched); app probe `RESTORE_OK` on every item (incl. fabric
  postgres-data 1271 files, neo4j-data 84, state 32). `live-proofs.json`
  extended (UFW tunnel-only posture, image pins, reseed stamps, dump GET +
  `gzip -t` round-trip `gzip-ok`); `live-reconciliation.json` refreshed
  (12 resources, plan empty). No unresolved reseed remains.

## 2026-09-14 — auditor 15:05 round (first-stage sudo, stale docs)

- First-stage sudo chicken-and-egg fixed at the root: the runner installs
  the sudo automation channel as step 0 (static `env_keep` content, no
  secrets, `visudo -cf` checked) BEFORE any `sudo -E` stage, from the
  single-source `scripts/lib/sudoers-automation-env`; bootstrap re-applies
  the same file as convergence. Without step 0, bootstrap loses
  `BOOTSTRAP_TARGET_HOST` before it could install the policy itself.
- Mechanism surprise documented: the preserved/fresh-26.04 sudo is sudo-rs
  0.2.13 (ignores `-E` without SETENV); classic sudo on 24.04 honors `-E`.
  Hence the regression test pins `ubuntu:26.04`.
- Executed clean-host regression (`scripts/test-sudo-channel.sh`, exit 0):
  disposable 26.04 container, bug reproduced without policy
  (`stripped=GONE`), `CHANNEL_OK` with the step-0 install
  (`stripped=freshhost` for the actual `BOOTSTRAP_TARGET_HOST` variable).
  Container destroyed via trap; debug orphans removed.
- Stale docs reconciled: `iac-interfaces.md` now consumes
  `ADMIN_CLOUDFLARE` (`CF_DEPLOY_TOKEN` marked historical/superseded);
  `iac-inventory.md` plan state is `empty` (vault-escrow paragraph marked
  historical/superseded, escrow owned by ensure-service-token + runner).

## 2026-09-14 — auditor 15:22 round (key-only, backend-before-wire, stage proofs, contracts)

- `--generate-key-only` no longer requires a host/zone (mint-first
  ordering); executed `--generate-key-only --dry-run` with empty
  PROVISION_HOST/ZONE exits 0. Live mint intentionally not exercised
  (it rotates the escrowed SSH pair + registers an OVH account key;
  operator action, not a test).
- Fresh backend before first mutation: new `ensure-fresh-backend.sh`
  generates backend.hcl (names/URLs only, verified secret-free) before
  wire --skip-verify; refuses preserved/unknown keys; idempotent. Adopt
  loads S3 auth via memory-only AWS_* env. Backendless --apply refusal
  retained as defense-in-depth. Clean-checkout partial state impossible
  by construction (order asserted in rehearsal).
- Per-stage live proofs: new `collect-stage-proofs.sh` -> 8/8 PASS at
  15:27Z (preserved-safety refusals, bootstrap docker29/ufw-deny/
  hello-world, coolify 9 healthy + origin 200, dashboard 200 + ssh 302,
  reseed stamps, instance RESTORE_OK, 16-line app RESTORE_OK, disposable
  TXT create+verify+delete with zero residue). Target /tmp clean.
- Contracts reconciled: interfaces R2 four fields; deployment-plan host
  timer sole plane (no Coolify in-app destination); terraform README
  OpenBao-only (no external manager/profile); inventory
  ADMIN_CLOUDFLARE primary.
- Report attestation hardened: rehearsal records code_tree_scripts/infra
  (content hashes); HEAD trees verified MATCH, code diff empty — the
  artifact attests the audited code regardless of docs-only follow-ups.
