# 08. Evidence register — Nomad migration (2026-09-18)

The retired control plane's chronological evidence log (2026-09-13…17) is
archived untouched at
`evidence-archive/08-iac-redesign-evidence.retired.md` (with the retired
live-proof JSONs beside it). This file records the migration itself: what
was removed, what replaced it, and what the cutover gate must prove.

## What was retired

- Docs: `docs/03-nomad.md` replaced the retired-plane install doc (same
  slot, rewritten); all runbooks (00–09, deployment plan, interfaces,
  inventory, rotation) rewritten Nomad-only.
- Scripts (deleted): the five retired-plane scripts (provision, live
  verify, onboarding verify, backup-rollback, backup-schedule — exact
  names in git history).
- Scripts (added): `provision-nomad.sh`, `verify-nomad-live.sh`,
  `rollback-nomad-snapshot.sh`, `schedule-host-backup.sh`.
- Terraform: UI DNS record + Access app re-created for `nomad.<domain>`;
  tunnel renamed to `nomad-admin` with a single `:4646` ingress rule;
  bucket default `ovh-host-backups`; service-token default
  `ovh-nomad-machine-verification`; state key
  `ovhcloud-nomad/terraform.tfstate`.

## Name mapping (retired → Nomad-era)

Every retired name (UI DNS + Access app, tunnel, R2 bucket, service
token, state key, all Bao entries under the retired prefix, the Bao
reader policy, the host timer unit + directory, the provisioner stage
name) maps 1:1 to the Nomad-era name used across this runbook. Exact
retired spellings are recovered from git history when needed (e.g.
`git log --all -S <nomad-era-name> --oneline` shows the renaming
commit with both sides) — they are deliberately absent here so the
active tree stays clean.

Migration mechanics per resource:

- UI DNS + Access app: destroy/recreate at the authorized apply.
- Tunnel: rename at apply (tunnel ID stable; DNS uses the tunnel ID).
- R2 bucket: new bucket + object copy at M5, then import.
- Service token: recreate + re-escrow at M5.
- State key: `init -migrate-state` at M5.
- Bao entries: duplicate to Nomad-era names, verify readback, delete
  old entries only after the Nomad plane proves healthy (M5 gate §6).
- Bao reader policy: recreate + re-mint the host accessor at M5.
- Host timer unit + directory: the new scheduler reinstalls at cutover.

## Preserved proofs (still valid)

- Workload backup/restore proofs 2026-09-14 (shop, runtime, dbproof:
  byte-identical + `CONNECT_OK`) — the workload scripts survive, only the
  platform exclusion changed.
- OVH Automated Backup API verification 2026-09-14.
- Tunnel create/delete API proofs, rehearsal methodology (paths renamed to
  `/tmp/ovh-nomad-rehearsal/`).

## Cutover gate (M5, operator)

1. OVH snapshot taken (fast-cut rollback, user-accepted).
2. Bao entries duplicated to Nomad-era names; readback verified.
3. Retired plane uninstalled; Nomad provisioned (ACL escrowed).
4. `rollback-nomad-snapshot.sh` reports `RESTORE_OK` (probe).
5. `verify-nomad-live.sh` green; UI 200 via service token; 80/443 denied.
6. Old Bao entries + retired DNS/bucket deleted after health holds.

## New-origin cutover evidence (2026-09-19, second migration)

New VPS `vps-c85da816.vps.ovh.ca` (148.113.245.89, BHS6) serves
nomad/ssh/registry/cognee through dedicated tunnel
`nomad-148-113-245-89`; preserved VPS keeps keeper/dump/unleash on
`nomad-admin`. OmniRoute/Fabric retired, never migrated. All outputs below
are redacted (statuses/digests only — no secret values anywhere).

`verify-nomad-live.sh` (PROVISION_HOST=148.113.245.89), exit 0:

```text
PASS edge leader endpoint (200)
PASS server members alive (1)
PASS client nodes ready (1)
PASS nomad ports loopback-only
PASS docker-firewall rules (docker-firewall rules present (ext_if=ens3).)
PASS no external listeners besides SSH (zero drops is correct: refused at interface)
PASS jobs healthy
PASS containers healthy
PASS backup timer (active)
ALL LIVE CHECKS PASS
```

Cognee on the new cluster (1 alloc, 0 failed; edge anon 401, authed
`cognee edge ok`); public smokes through `https://cognee.pkubelka.cz`:

```text
Status        = running
57bcb781  d9619812  cognee      0        run      running
SMOKE PASS (mcp)    # initialize/remember/recall(CHUNKS) all 200
SMOKE PASS (rest)   # add/cognify/search(CHUNKS) all 200
```

Registry through `https://registry.pkubelka.cz` (login OK; push/pull
digest-identical; container ran `Hello from Docker!`):

```text
[registry.pkubelka.cz/smoke/hello-world@sha256:d1a8d0a4eeb63aff09f5f34d4d80505e0ba81905f36158cc3970d8e07179e59e]
```

Snapshot restore probe on the new host (production table reproduced):

```text
RESTORE_OK: scheduled R2 snapshot restores to usable state; probe agent killed.
```

Terraform: reviewed plan (1 add, 8 change, 4 destroy — all intended) applied
clean; second plan exit 0: `No changes. Your infrastructure matches the
configuration.`

Repo gates on the cutover HEAD: `validate-iac.py` pass,
`validate-repository.sh` pass, `rehearse-fresh-environment.sh` 11/11 pass.

Field incidents fixed durably during the cutover: runner gossip-escrow
clobber (old ACL rescued to `NOMAD_BOOTSTRAP_PRESERVED`), stale
`backup-r2-reader` policy paths, snapshot `mktemp` refusal, Nomad-blind
workload backup gap, provider service-token version trap (object now
API-managed, policies bind token ID), rehearsal dummy vars for the two new
TF variables. Human OTP login on the new Nomad UI verified by the operator.

## Old-VPS data migration (2026-09-19, pre-termination)

Operator decision changed to full decommission (user cancels the old service
themselves). Before that, all remaining old-host data was pulled to the new
host under `/srv/old-vps-migration/` (~15 GB):

- `nomad-volumes/` — full copy of old `/opt/nomad-volumes` (14.0 GB:
  dump-pg-dev/prod, 6.5 GB dump-prod-media, unleash-pg, old registry blobs,
  registry-auth, snapshots). Size parity source/dest confirmed.
- `keeper-sqlite/staging-2026-09-{17,18,19}/` — the dump job's fresh keeper
  `storage.sqlite` copies (Sept 19 copy byte-identical at 181,927,936 B;
  `PRAGMA integrity_check` = ok, 136 tables). These never reached R2 (Sept
  14-stale `app-databases/`/`app-volumes/` prefixes) so the old disk was the
  only fresh copy.
- `docker-volumes/` — keeper-data, dump-media, redis-data, fabric
  postgres/neo4j/state (retired scope, archived), coolify-db/redis.
- `*.sql` — portable `pg_dumpall` dumps taken via temp containers against
  the quiesced clusters (dump-pg-prod 9 tables, dump-pg-dev 9 tables,
  unleash-pg 91 tables; PG 17 / PG 17 / PG 16; socket-local trust auth).
- All 15 remaining old Nomad jobs stopped+purged first (0 running verified);
  automated-backup restore point `2026-09-19T15:00:04Z` confirmed as
  full-VPS fallback. OVH snapshot option is not enabled on the old service
  (`createSnapshot` 400), so no pre-termination snapshot was possible.

Hygiene: a single-use migration SSH key was minted, trusted old→new only for
the pull, then revoked from both hosts (each `authorized_keys` back to the
operator key only); local private material shredded.

## Old-VPS decommission executed (2026-09-19, operator-ordered)

- All 15 remaining old Nomad jobs stopped+purged; `job status` shows 0 running.
- Service canceled by the operator: `deleteAtExpiration: true`, expiration
  2027-09-13, auto-renew off (termination lands at period end per OVH).
- VM powered off via API (`stopVm` done; SSH to 57.129.155.203 times out;
  list-state still reports `running` until OVH processes the stop).
- `ovh_vps.preserved` block deleted from `infra/terraform/main.tf` and
  `ovh_vps.preserved[0]` removed from state (the separately authorized
  workflow the block comment required).
- Tunnel `edge_new` ingress re-pointed to the live edge-proxy port :31297
  (dynamic port had drifted from :24051); final `terraform plan
  -detailed-exitcode` exit 0: "no differences, so no changes are needed".

## Resurrection cutover (2026-09-19/20, operator-ordered)

Unleash + dump + control-panel + flags redeployed on the new VPS from the
migration archive (specs were host-local on the expired old VPS).
- Images rescued via temp registry from migrated blobs, pushed to the new
  registry (`dump/control-panel/eg-flags:restored-20260919`); Unleash uses
  upstream `unleashorg/unleash-server` (note: `unleashorg/unleash` no longer
  exists on Docker Hub).
- Data restored to live `/opt/nomad-volumes` paths with byte parity; PG
  role passwords reset post-restore and escrowed (`secret/projects/dump/env`,
  `secret/projects/unleash/env` + `/api` + `/admin`).
- Public hostnames cut to the new tunnel via reviewed plan + authorized
  applies (3 DNS imports + 4 ingress rules; second plan empty, exit 0):
  `unleash` 200 GOOD, `control` 200, `flags-listener` 200.
- `dump.petrzdena.cz` (other account): CNAME repointed to the new tunnel;
  the shadowing dead tunnel `dump-nomad` (d0dcdce3, down) in the petrzdena
  account was deleted to release the route. Edge route convergence pending
  (1033/530 flap at PRG as of 00:05Z).
- Loader fix: OVH discovery now selects a `running` service (the expired old
  VPS answers 460 to sub-calls and broke every TF run).
- Gate fix: `validate-repository.sh` retired-plane needle now excludes two
  documented false positives (operator SSH key filename, legacy R2 object
  prefix in this evidence file).
- Rogue `keeper` job (22:58, failed) purged — keeper stays archived per
  operator pick. Control-panel old dashboard state unrecoverable
  (was container-local); boots fresh.
