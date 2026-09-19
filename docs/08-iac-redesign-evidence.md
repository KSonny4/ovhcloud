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
