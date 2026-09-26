# SPECS-W1 journal — Meta Muse Spark (lane SPECS-W1)

- Issue: KSonny4/platform#16 (Slice N step 6: Git follow-up for the wave-1 memory resize).
- Plan: `please-create-a-plan-majestic-island.md`, Slice N ("only the watcher deploys"; this lane
  is the approved same-day Git follow-up so the future watcher agrees with what is live).
- Worktree: `.worktrees/specs-w1`, branch `fix/wave1-memory-specs-16`, base `origin/master`
  `6683f06` (reused from the pre-ENOSPC run; worktree was clean but one commit behind, reset to
  origin/master before editing).
- Role: repo PRs only. No Nomad submit, no Bao write, no SSH. One read-only live re-check via the
  Nomad API (auth redacted, only Resources + image read) confirmed the 13:11Z live-vs-old table
  was still current before editing.

## Changes (resources only, live values already running since 2026-09-26)

| file | task | old `memory` | live `memory` | live `memory_max` |
|---|---|---|---|---|
| jobs/flags-listener.nomad.hcl | listener/listener (flags-listener) | 256 | 64 | 256 |

The committed spec carried no `memory_max` (oversubscription is new); added with the live value.
CPU and image identical to live — no other drift, nothing else changed.

## Notes

- `nomad fmt -check` flags this file, but the only inconsistency (image/ports alignment in the
  `config` block, lines 70-71) is pre-existing on `origin/master`; the edited `resources` block
  is fmt-canonical. Left untouched per the bounded-scope rule.
- Lane STALEAUTH-REPO's platform PR #21 touches ACL scripts, not this spec file; no conflict.
  Base is default branch.

## Checks

- `nomad job validate jobs/flags-listener.nomad.hcl`: successful.
- `git diff --check`: clean. Added-lines secret scan: clean.
- `scripts/validate-iac.py`: passed. `unittest discover -s tests`: 18 tests, OK.
- `bash -n scripts/validate-repository.sh`: clean.
- GitHub Actions is blocked account-wide by billing (pre-existing); local gates are the proof.
- Do NOT merge (orchestrator merges).
