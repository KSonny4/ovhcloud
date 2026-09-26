# Agent journal: Slice 4 repo ACL (deployer + sandbox)

- Started: 2026-09-26T13:11Z
- Agent/session: Meta Muse Spark (lane ACL-S4), sole writer in this worktree
- GitHub Issue(s): KSonny4/platform#26
- Task: Slice 4 repo part — deployer/agent-sandbox policies, sandbox namespace, contract test, dry-run-by-default apply script
- Intended outcome: committed ACL boundary so only the watcher can submit to production namespaces; agents keep a sandbox; nothing applied
- Repository: KSonny4/platform
- Starting ref: origin/master f5e7e56
- Branch/worktree: feat/acl-s4-26 in platform/.worktrees/acl-s4
- Guidance: platform AGENTS.md (OVHcloud runbook) + engineering-guidance standards/outcome-reporting.md and standards/agent-journal.md. Shared-guidance adoption overlay: docs/engineering-guidance.md rev 474b8c21 (L1 informative, prepare-only).
- Status: active

## Timeline

- 13:10Z — Cognee recall attempted twice (MCP 502, `cognee-guard recall` CLI 502): memory unavailable, not a no-match. Continued with repo-only evidence per guard fallback.
- 13:11Z — Created worktree feat/acl-s4-26 off origin/master; created issue #26 (objective, scope, acceptance checks, plan link).
- 13:12Z — Read origin/master agent-reader policy/test/apply script plus polymarket t1 ACL pattern and its test; verified quota + node_pool_config are Enterprise-only in the official Nomad namespace/quota spec docs (so this OSS cluster takes the documented-memory-cap branch).
- 13:15Z — Wrote acl/namespaces.json (single data file), acl/deployer.policy.hcl, acl/agent-sandbox.policy.hcl, acl/namespace-sandbox.hcl, jobs/sandbox-sweep.nomad.hcl, scripts/apply-acl-s4.sh, tests/test_acl_s4.py.
- 13:16Z — First test run: 29/30 (agent-reader `*` glob tripped the data-file label check). Fixed the test to allow `*` only for read-only blocks.
- 13:17Z — 30/30 green; apply script dry-run works offline (exit 0); bash -n + shellcheck clean.
- 13:18Z — Wrote docs/acl-cutover-runbook.md (sandbox constraints, owner apply, Bao cutover as runbook-only later [YES], verification, rollback) and docs/03-nomad.md section 9 pointer.

## Decisions

- Namespace names are data in acl/namespaces.json; policies carry literal blocks (Nomad needs literals) with headers pointing at the data file, and the test + apply-script preflight enforce consistency. The agent-reader `*` glob is grandfathered as read-only only.
- deployer has no dispatch-job (dispatch stays with narrow per-project tokens); agent-sandbox has no node block and no stop/scale (sweep runs privileged in default).
- Namespace spec omits `quota` and `node_pool_config` (both Enterprise-only on this OSS cluster); the home pin is a per-job-spec rule plus review until Slice P / Enterprise. Sweep spec pins `node_pool = "default"`, runs in `default`, fails closed without injected auth.
- Did not touch scripts/validate-repository.sh (it runs no unittest suite; same call as the agent-reader lane) and did not change any existing policy.

## Artefacts changed

- acl/namespaces.json, acl/deployer.policy.hcl, acl/agent-sandbox.policy.hcl, acl/namespace-sandbox.hcl (new)
- jobs/sandbox-sweep.nomad.hcl, scripts/apply-acl-s4.sh, tests/test_acl_s4.py (new)
- docs/acl-cutover-runbook.md (new), docs/03-nomad.md section 9 (added)
- This journal file

## Checks and evidence

- `python3.14 -m unittest discover -s tests -p 'test_acl_*.py'` — 30 tests OK (8 pre-existing agent-reader + 22 new)
- `bash scripts/apply-acl-s4.sh` (default dry-run, offline) — exit 0, plan only
- `bash -n` + `shellcheck scripts/apply-acl-s4.sh` — clean
- Pending: `bash scripts/validate-repository.sh`, `git diff --check`, secret grep, commit, PR

## Reflection and knowledge saved

- Lesson: a data-file consistency test must grandfather the pre-existing read-only `*` glob explicitly (allow glob only when no write-shaped capability is present) instead of failing it or exempting the file by name. Delivery: pending — Cognee unavailable (502 on both paths); will retry `cognee-guard remember` at session end and record the outcome here.

- 13:22Z (resume) — Previous run killed ~13:15Z by ENOSPC; disk now 50% used. Reused worktree/branch/issue #26 per resume rules; kept all partial work as sound after verifying against origin/master agent-reader pattern, the plan Slice 4 text, and committed job specs (no namespace pins anywhere, so production = ["default"] is correct). Removed tests/__pycache__ build output. Gates re-run green (below); committing and opening PR next.
