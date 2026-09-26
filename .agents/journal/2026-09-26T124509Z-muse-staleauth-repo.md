# Agent journal: drop inline registry auth from repo job specs (STALEAUTH-REPO)

- Started: 2026-09-26 ~12:07 UTC (lane prompt mtime); finished 2026-09-26T12:45:09Z UTC (last progress.log line; lane .out `exit=0`)
- Agent/session: Meta Muse Spark (lane STALEAUTH-REPO)
- GitHub Issue(s): KSonny4/polymarket-wallet-finder#2438
- Task: lane prompt STALEAUTH-REPO — owner approval 2026-09-26 14:05 CEST ("Two-track fix", track 2, repo PRs): repo-only removal of inline docker `auth {}` blocks and registry-password `-var`/variables from committed Nomad job specs, so no manual `nomad job run` from a repo re-adds stale credentials. NO live action (no Nomad API, Bao, SSH).
- Intended outcome: one PR per owning repo; map of job→repo→files; #2438 comment; no merges
- Repositories written (each from a NEW worktree off the default branch, never the main checkout): KSonny4/cognee-setup, KSonny4/x-as-llm-api, KSonny4/JevCorpoLint, KSonny4/graph-engineering
- Starting refs: each repo's `origin/<default>` at lane time (PR bases: main / main / master / master)
- Branch/worktree per repo: `fix/drop-inline-registry-auth-2438` under `<repo>/.worktrees/staleauth-2438`
- Guidance: lane prompt STALEAUTH-REPO; engineering-guidance AGENTS.md rules 8–9 + standards/agent-journal.md; project AGENTS.md L1 informative only; one Cognee recall (registry auth in job specs)
- Status: completed — 4 PRs open, none merged (`exit=0`)

Persisted by the orchestrator from the lane hand-off (the lane could not commit its own journal).

## Timeline

- Step 0: Cognee recall (registry auth in Nomad specs); AGENTS.md rules 8–9 + agent-journal standard read.
- Step 1, spec hunt (read-only, excluding `.worktrees/`, `*-wt-*`, `_archive/`, `node_modules`): committed specs + the registry-password `-var` flag / `REGISTRY_PASSWORD` deploy plumbing mapped per parent job → `$S/staleauth-repo/map.md` (full table). No committed spec in Git: bare `keyround` (only keyround-periodic/manual specs exist — live keyround/dispatch-* are parameterized dispatches, covered by x-as-llm-api PR); `keeper-staging` (spec exists ONLY as an untracked file in a dirty checkout — untouched per worktree rule; owner follow-up: commit or delete it, then strip auth the same way).
- Step 2, four PRs (all OPEN, none merged; every diff token-grepped clean before commit):
  - cognee-setup #7 (`8d56e81c`): docker `auth {}` + `registry_user`/`registry_password` vars out of 11 job files (cognee, cognee-alloy, cognee-blue, cognee-ingest, cognee-snapshot, guard-heartbeat, ops-run, remember-drain, traffic-count + blue-gates/dual-mount-probe same pattern); registry vars dropped from `scripts/deploy.sh` + `scripts/cutover.sh`; TestRegistryAuth inverted to assert NO task carries registry auth; overlay note. No CI in repo; offline: full suite 21/21, rollback-guard.sh ALL PASS, `nomad job validate` on all 11 files, `git diff --check` clean. Note: blue job file regenerated via repo's own `render-blue.py` (pre-existing blue drift re-synced as its test requires). `https://github.com/KSonny4/cognee-setup/pull/7`
  - x-as-llm-api #13 (`43f9eb97`): `auth {}` + `dr_user`/`dr_pass` out of 5 specs (keeper, keeper-probe-shell, keyround-manual, keyround-periodic + zencli-validate); `-var` examples replaced with client-level-auth note; session journal added. No CI; `git diff --check` clean; zero remaining `var.dr_user`/`var.dr_pass` refs and no docker `auth {}` repo-wide; `nomad job validate` OK on 4/5 (keeper.nomad.hcl fails on unset deploy-time vars — identical on unedited origin/main, pre-existing); pytest scripts tests 11 passed. Note: worker ran bare `nomad fmt` (write mode) mid-lane — detected via `diff --stat`, restored, edits re-applied and re-verified. `https://github.com/KSonny4/x-as-llm-api/pull/13`
  - JevCorpoLint #15 (`36a48133`): template `auth {}` with `__REGISTRY_USER__`/`__REGISTRY_PASSWORD__` removed; renderer env-plumbing + placeholder replacement removed; registry tests rewritten; deployment.md/rollback.md updated. pytest scripts/tests 30 passed, renderer validate passed, `git diff --check` clean. CI FAILED at job start — pre-existing account billing/spending-limit cause (last three master pushes fail identically). `https://github.com/KSonny4/JevCorpoLint/pull/15`
  - graph-engineering #466 (`50f22f7f`): `--registry-auth` injection removed from `tools/nomad_submit.py`; `registry_username`/`password_inline` params + flags + auth rendering removed from `ops/nomad/render_job.py`; spec headers + docs updated; `test_registry_auth_*` tests removed; session journal added. test_nomad_render 37 passed; submit/dispatch/spec suites 175 passed; `nomad job validate` on all 5 specs; `git diff --check` clean. CI (test, gate, ocr-review) fails at startup — same billing cause, no test ran. Historical `docs/explained/reports/2026-09-20-outage-fix.html` left intact as history. `https://github.com/KSonny4/graph-engineering/pull/466`
- Skipped (recorded): KSonny4/platform (handled by REGAUTH-2438 PR #25); dump (committed `nomad/dump.nomad.hcl` already clean, no password anywhere — no PR needed); openbao/registry/edge-proxy + dom.ops-* specs (out of scope); ovhcloud-grafana-alloy dir (a platform checkout, not its own repo); NomadSetup dir (not a git repo).
- Step 3: `result.md` written; ONE #2438 comment (`issuecomment-5846379905`, token-grep first); lesson saved via `cognee-guard remember`.
- Deploy-doc wording used everywhere: registry auth is client-level on the node (KSonny4/platform `config/nomad.hcl`, docker plugin `auth { config = ... }`); job specs must not carry `auth`.

## Decisions

- One PR per repo (not one mega-PR) — separate owners/merges; platform excluded (REGAUTH-2438 owns it).
- Bare `nomad fmt` damage detected and fully restored rather than kept — formatting-only churn is out of scope.
- Historical outage report left untouched — history, not live config.

## Artefacts changed

- 4 open PRs: cognee-setup#7, x-as-llm-api#13, JevCorpoLint#15, graph-engineering#466 (+ SHAs above)
- #2438 comment `issuecomment-5846379905`
- `$S/staleauth-repo/`: `map.md`, `result.md`, `progress.log`
- Nothing merged (orchestrator/other owners merge).

## Checks and evidence

- Per-repo offline gates as listed above (test suites 21/21 + 11 + 30 + 37/175; `nomad job validate`; `git diff --check`; added-lines secret scans — all clean/passed)
- CI: none in cognee-setup/x-as-llm-api; billing-blocked (pre-existing, master reproduces) on JevCorpoLint/graph-engineering
- Token-grep before every commit/comment — clean; never printed or committed a password/auth string/token

## Reflection and knowledge saved

- Recalled context: registry-auth-in-specs recall; AGENTS.md 8–9 (issue-first, journal).
- Lesson / what worked: `diff --stat` after any tool that might rewrite files catches stray `nomad fmt`-style damage early; inverting the auth test (assert ABSENCE) locks the fix.
- Memory delivery: saved (via `cognee-guard remember`, per lane report).

## Blockers / unresolved

- Owner follow-ups (in result.md + #2438 comment): keeper-staging untracked spec (commit or delete, then strip); resolve Actions billing → re-run checks on #15/#466 → merge all 4.
- Pre-existing failures preserved as-is: keeper.nomad.hcl deploy-time-var validate failure; billing-blocked CIs.

## Handoff

- Final status: completed
- Remaining work: none for this lane (merges + billing belong to owners)
- Next safe action: owners review/merge the 4 PRs after CI re-runs where applicable
- Authoritative references: `$S/staleauth-repo/map.md` + `result.md` + `progress.log`; `$S/STALEAUTH-REPO.out` (`exit=0`); PRs #7/#13/#15/#466; #2438 comment 5846379905
