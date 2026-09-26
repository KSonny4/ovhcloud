# Agent journal: strip stale inline registry auth, live — first pass (STALEAUTH-LIVE)

- Started: 2026-09-26T12:19:02Z UTC (progress.log step0); stopped 2026-09-26T12:33:00Z UTC by orchestrator to narrow scope (per successor prompt STALEAUTH-LIVE2.md); lane .out left empty
- Agent/session: Meta Muse Spark (lane STALEAUTH-LIVE)
- GitHub Issue(s): KSonny4/polymarket-wallet-finder#2438 (relates to KSonny4/platform#16)
- Task: lane prompt STALEAUTH-LIVE — owner approval 2026-09-26 14:05 CEST ("Two-track fix"): strip ONLY the inline docker `auth` key from live specs in batches (periodic/batch/parameterized parents first — re-registering restarts nothing; then non-critical services; cognee last), one job at a time with health checks. Wave-1 jobs wait for the watcher fix.
- Intended outcome: in-scope live jobs pull via node-level auth (live since 12:05Z per REGAUTH-2438); evidence for the "failing now" claim; no commits
- Repository: none written (no Git commits per hard rules); live Nomad jobs only
- Starting ref: live state per `$S/regauth/inline-auth-jobs.txt` + `$S/regauth/result.md` (read first, per Step 0)
- Branch/worktree: none (live lane)
- Guidance: lane prompt STALEAUTH-LIVE; project AGENTS.md L1 informative only; one Cognee recall (inline/stale auth)
- Status: stopped by orchestrator mid-batch-A (Step 1 inventory + first strip done); continued by lane STALEAUTH-LIVE2 (same `$S/staleauth` dir, same progress.log)

Persisted by the orchestrator from the lane hand-off (the lane could not commit its own journal).

## Timeline

- 12:19:02Z — Step 0: Cognee recall (15 hits); regauth progress.log + result.md read (node auth live 12:05Z, method confirmed); wave-1 watcher pid alive check; tunnel leader 200.
- Step 1, read-only inventory — For every in-scope parent job (namespace, type, periodic/parameterized flags, JobModifyIndex, Version, auth-carrying tasks; last-3-children status + 401/pull-error counts for periodic/parameterized parents): saved `$S/staleauth/inventory.md` + `inventory.json` (via `inventory.py`). Finding: guard-heartbeat, remember-drain, traffic-count children showed repeated pull-error clusters (6–8 pull-fail events per 10–20 scanned) before the strip — evidence for the "periodic runs failing now" claim (Nomad GCs an unused image ~3 min after its last container stops).
- 12:31:45Z — Step 2 batch A, first submit: traffic-count v2→v3 (1 auth block removed in python memory; CAS with live JobModifyIndex; verified `auth present: false`; no running allocs — none to disturb; submit OK).
- 12:33Z — Orchestrator stopped the lane to narrow scope. No further submits; no #2438 comment and no `result.md` from this lane (Step 5 belongs to the successor).

## Decisions

- traffic-count first (periodic parent: re-register restarts nothing running) — per batch-A order.
- Periodic parents: wait for the next natural run if due within 15 min (no force-launch); parameterized parents: no dispatch ("fixed, unproven until next dispatch") — per Step 2 rules.
- Out-of-scope respected, none touched: keeper/keeper-staging (REGAUTH-2438), wave-1 jobs (watcher fix pending), openbao/registry/edge-proxy/dom.ops-*/rec.shadow/watcher, non-default namespaces unless verified non-trading.

## Artefacts changed

- Live: traffic-count v2→v3 (auth-free; proof of clean pulls left to successor lane)
- `$S/staleauth/`: `inventory.md`, `inventory.json`, `inventory.py` (Step 1 evidence); shared `progress.log` (this lane's lines: step0 + traffic-count submit)
- No commits; watcher untouched (its "NON-wave-1 trip (alert only)" lines for failing periodic children are expected evidence, not a STOP cause)

## Checks and evidence

- Post-submit verify: new version `auth present: false`; running allocs unchanged (none existed)
- Pre-strip 401/pull-error clusters counted from child task events (values never printed)
- No secrets in any artefact (names/versions/IDs/counts only; tokens via env)

## Reflection and knowledge saved

- Lesson / what worked: inventory-first (Step 1) turns the "failing now" assumption into counted pull-error evidence before any submit; periodic-first ordering keeps the blast radius at zero running allocs.
- Memory delivery: none recorded in this lane's materials (lesson saved by successor lane).

## Blockers / unresolved

- Lane stopped mid-batch-A — all remaining strips + proofs + Step 5 report handed to STALEAUTH-LIVE2 (which completed them; its journal covers the outcomes).
- traffic-count v3 clean-pull proof — pending at stop; done by successor.

## Handoff

- Final status: stopped (orchestrator scope-narrowing at 12:33Z); continued by STALEAUTH-LIVE2
- Remaining work: all remaining batch-A/B submits, proofs, #2438 comment, result.md — succeeded-by lane
- Next safe action: (was) resume batch A per STALEAUTH-LIVE2 scope — already executed
- Authoritative references: `$S/STALEAUTH-LIVE.md`; `$S/staleauth/inventory.md` + `inventory.json`; shared `progress.log` (12:19:02Z, 12:31:45Z lines); `$S/STALEAUTH-LIVE2.md`
