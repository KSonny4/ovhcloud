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
