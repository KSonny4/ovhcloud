# Platform correction — worker journal

- Issue: KSonny4/ovhcloud#6; lane `.worktrees/nomad-release-baseline-6`, branch
  `publish/nomad-current-host-baseline-6`, base `ad6cbfe`, prior HEAD `1b84781`.
- Role: implementation worker; no prod/SSH/apply; no secrets read; no nested agents.
- Guidance actually loaded: owning `AGENTS.md`, `CONTEXT.md` (head),
  `docs/engineering-guidance.md` (via grep); shared guidance at the lane pin —
  `AGENTS.md`, `authority/authority.md`, `standards/operations.md`,
  `standards/secrets.md`. No Superpowers skill used.

## Changes (review BLOCK items, this lane only)

1. `scripts/backup-app-workloads.sh`: `topology_entry()` now redacts exact names
   `DATABASE_URL`/`DB` plus any value shaped as a URI with userinfo
   (`scheme://user:pass@host/...`); comment updated. Reviewer fixture
   (`DATABASE_URL`+`DB` postgres URIs) now yields `REDACTED` + name listing.
2. `jobs/cognee.nomad.hcl`: edge-common `log` replaced with a
   `format filter` block (`wrap json`, `request>headers>X-Api-Key delete`).
   Caddy default redaction does not cover that header; output shape unchanged.
3. `scripts/verify-live-reconciliation.sh`: no longer requires the deleted
   `ovh_vps.preserved` record. Requires `resource "ovh_vps" "platform"` +
   `prevent_destroy`, accepts `ovh_vps.platform` (provision) or
   `data.ovh_vps.existing` (import) in state, fails closed if a preserved
   record reappears, records `vps_mode` in evidence. Families list updated.
   `infra/terraform/variables.tf`: `manage_existing_vps` description corrected
   (preserved resource retired 2026-09-19).
4. `scripts/lib/preserved-guard.sh`: identity now the current origin
   (`vps-c85da816.vps.ovh.ca`, fallback `148.113.245.89`); decommissioned
   `vps-1525c977` entry removed. `scripts/collect-stage-proofs.sh` stage 1
   asserts refusal of the current name/IPv4.
5. `scripts/verify-nomad-live.sh`: cognee `unhealthy` carve-out narrowed from a
   broad `^server-[0-9a-f-]+` name exclusion (matched all three jobs owning a
   `server` task) to a Docker-label identity check (`job_name/task_name ==
   cognee/server`); other `server-*` unhealthy still fails.
- `scripts/rehearse-fresh-environment.sh`: regression gates — topology fixture
  extended with `DATABASE_URL`/`DB` URIs + leak-absence assert (18 assertions);
  guard fallback assert updated; structural asserts for the Caddy filter, the
  narrowed health exception, and the current reconciliation record.

## Checks actually run

- `python3 /tmp/nomad-platform-review-6/run-gate.py` (bounded
  `scripts/validate-repository.sh`): exit 0, 17.8s, 5/5 groups.
- `shellcheck` on all six touched scripts + `bash -n`: clean.
- `gitleaks detect` range `ad6cbfe..HEAD`: exit 0, no leaks. Full-tree scan
  flags 5 pre-existing historical hits (deleted fabric jobspec, retired
  scripts, old live-proofs); byte-identical before/after this diff.
- `--self-test-topology` on the reviewer fixture shape: both URIs REDACTED.
- Guard executed offline: current name + IPv4 refused (rc=2), unrelated allowed.
- Narrowed-exclusion loop simulated with stubbed transport: cognee unhealthy
  excluded, control-panel unhealthy retained.

## Not proven / residual

- No live run: reconciliation, Nomad label check, and Caddy filter are
  unproven against the running host (no SSH/apply per contract); operator
  verifies on the next authorized live pass.
- `caddy validate` not available locally; filter syntax follows Caddy docs.
- Evidence-collection SSH defaults still point at the decommissioned host
  (`recreate-workload.sh`, `collect-live-evidence.sh`, `collect-stage-proofs.sh`,
  `test-sudo-channel.sh`); left untouched as out of scope for this correction.
- New-origin IPv6 is not committed anywhere found; guard v6 membership stays
  API-derived with an IPv4-only fallback.
