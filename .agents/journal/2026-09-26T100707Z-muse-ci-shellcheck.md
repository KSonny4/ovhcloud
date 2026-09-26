# Agent journal: CI shellcheck green (issue #19)

- Started: 2026-09-26T10:07:07Z
- Agent/session: muse (lane CI-19, worktree ci-shellcheck-19)
- GitHub Issue(s): KSonny4/platform#19
- Task: Make platform master CI green again (shellcheck SC2002/SC2015)
- Intended outcome: PR against master with green validation, fixing shellcheck findings in source and unifying local/CI behaviour
- Repository: KSonny4/platform
- Starting ref: b7e26d3 (origin/master)
- Branch/worktree: fix/ci-shellcheck-19 @ ~/git_projects/platform/.worktrees/ci-shellcheck-19
- Guidance: platform AGENTS.md (CONTEXT.md source of truth; infra plan reviewable non-live; scripts/validate-repository.sh entrypoint); shared guidance L1 informative per AGENTS.md
- Status: active

## Timeline

- 2026-09-26T10:02Z — Cognee recall "platform CI shellcheck validation red SC2002 SC2015" (15 memories, mostly graph-engineering baseline noise; no platform-specific shellcheck lesson; proceeding against current source).
- 2026-09-26T10:03Z — Read .github/workflows/validate.yml and scripts/validate-repository.sh; pulled latest failed run log via `gh run view --log-failed` (run 36234280214). Exact findings: 16 locations — SC2002 in healthcheck.sh:12, lib/s3-multipart.sh:251; SC2015 in verify-nomad-live.sh:34, rehearse-fresh-environment.sh:204,239,242,456,462,464,493,494, rollback-app-workloads.sh:415,471, wire-fresh-edge.sh:137, emit-fresh-imports.sh:36, adopt-fresh-edge.sh:26.
- 2026-09-26T10:04Z — Diagnosed root cause: version drift. Local Homebrew shellcheck 0.11.0 hides SC2002 (optional `useless-use-of-cat` off by default) and no longer emits SC2015 for `|| true` / `exit`-guard idioms; runner's preinstalled 0.9/0.10 reports both by default. Local `shellcheck` exited 0 while CI failed.
- 2026-09-26T10:05Z — Fixed all findings with behaviour-preserving if/else and input-redirection rewrites (8 files). Added repo `.shellcheckrc` (severity=style + enable=useless-use-of-cat) as the single source of truth; pinned CI shellcheck to 0.11.0 via binary install step in validate.yml.
- 2026-09-26T10:06Z — Verified: `bash -n` clean on all changed scripts; `git diff --check` clean; repo shellcheck 0.11.0 pass; emulated old-runner flags pass; downloaded 0.9.0 + 0.10.0 binaries both pass; full `bash scripts/validate-repository.sh` passes (terraform validate + graft check OK).

## Decisions

- Fix in source with explicit `if` guards, not inline disables — matches issue acceptance (no global suppress, check stays in validation path).
- `grep file` / `tr < file` for SC2002 — behaviour-preserving, suggested by shellcheck wiki.
- `if [ -z ... ] || ...; then ...; fi` for guard-style `A && B || { exit; }`; `if cond; then ...; fi` for `... && { exit 1; } || true` negative assertions; `if [ -n ... ]; then cmd || true; fi` for best-effort docker connect — preserves set -e semantics and fail-closed behaviour.
- Also fixed rehearse-fresh-environment.sh:527 (same `&& ... || true` pattern inside dbflags loop, not in the failed-run log but same class) and converted `$(cat f)` to `$(< f)` on lines 492-493 to avoid future UUOC-class findings.
- ONE place for options = repo `.shellcheckrc`; version pinned in CI to 0.11.0 (matches local Homebrew) so Mac and runner apply identical rules.

## Artefacts changed

- scripts/healthcheck.sh (SC2002)
- scripts/lib/s3-multipart.sh (SC2002)
- scripts/verify-nomad-live.sh (SC2015)
- scripts/wire-fresh-edge.sh (SC2015)
- scripts/emit-fresh-imports.sh (SC2015)
- scripts/adopt-fresh-edge.sh (SC2015)
- scripts/rollback-app-workloads.sh (2x SC2015)
- scripts/rehearse-fresh-environment.sh (8x SC2015 + cat modernization)
- .shellcheckrc (new)
- .github/workflows/validate.yml (pinned shellcheck 0.11.0)
- This journal (to be committed)

## Checks and evidence

- `bash -n` on every changed script — all OK
- `git diff --check` — clean
- `shellcheck` (0.11.0, repo rc) on the 30-file validation list — PASS
- `shellcheck -S style --enable=useless-use-of-cat` emulation — PASS
- shellcheck 0.9.0 binary on validation list — PASS
- shellcheck 0.10.0 binary on validation list — PASS
- `bash scripts/validate-repository.sh` — "Repository validation passed." (exit 0)
- PR #22 opened (eb68b87); CI watch attempt 1: shellcheck findings GONE, but validation still red on `graft not installed` — the wrong npm package `graft@0.3.1` (microservices framework, no `graft` binary) was masking behind the shellcheck failure. Local uses `@nanonets/graft@0.19.0`.
- Attempt 2: fixed install line to `npm install --global @nanonets/graft@0.19.0` (matches local 0.19.0) — pending push + CI re-watch.

## Reflection and knowledge saved

- Recalled context: cognee_recall "platform CI shellcheck validation red SC2002 SC2015" — 15 hits, none platform-shellcheck specific; treated as context only.
- Attempt / struggle: local shellcheck 0.11.0 exited 0 on files CI flagged — surprising until `--list-optional` showed `useless-use-of-cat` is now opt-in and SC2015 no longer fires for `|| true`/exit-guard idioms.
- Lesson / what worked: compare `shellcheck --version` + `--list-optional` first; fix the source to satisfy the oldest runner version AND pin CI to the newest, with options in `.shellcheckrc` — then verify with downloaded old binaries.
- Applicability and evidence: any repo where Homebrew (rolling) and ubuntu-latest (frozen) shellcheck coexist; evidence scripts/healthcheck.sh:12 + validate.yml pin in this PR.
- Next time / source correction: none (no shared source to correct).
- Memory delivery: pending (to save at session end)
- Destination and keys: agent-memory-ksonny4-platform (pending)
- Verification: pending recall check
- Pending sync: none yet
- No-new-learning reason: n/a (lesson to save)

## Blockers / unresolved

- None yet; PR CI result pending.

## Handoff

- Final status: active
- Remaining work: commit + push + open PR (Fixes #19) + watch checks (max 10 min, max 3 attempts) + comment on #19; do NOT merge.
- Next safe action: `git add -A && git commit` then push/PR.
- Authoritative references: failed run 36234280214; issue KSonny4/platform#19; worktree ~/git_projects/platform/.worktrees/ci-shellcheck-19 @ b7e26d3.
