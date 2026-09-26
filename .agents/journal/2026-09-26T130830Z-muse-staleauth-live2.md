# Agent journal: strip stale inline registry auth, live — batches A+B (STALEAUTH-LIVE2)

- Started: 2026-09-26T12:36:24Z UTC (progress.log step0); finished 2026-09-26T13:08:30Z UTC (lane .out mtime; .out ends `exit=0`; last progress.log line 13:06Z step5 done)
- Agent/session: Meta Muse Spark (lane STALEAUTH-LIVE2)
- GitHub Issue(s): KSonny4/polymarket-wallet-finder#2438 (relates to KSonny4/platform#16)
- Task: lane prompt STALEAUTH-LIVE2 — continuation of STALEAUTH-LIVE (stopped 12:33Z): strip ONLY the docker `auth` key from 9 named live jobs (8 periodic/parameterized parents + service cognee-alloy), one at a time with the Step 2/3 method; read-only stale-check (boolean only) on cognee-blue, cognee, keeper-probe-shell; report.
- Intended outcome: 9 jobs auth-free and verified; deferred/stopped jobs documented with rotation-break booleans; #2438 comment + result.md; no commits
- Repository: none written (no Git commits per hard rules); live Nomad jobs only
- Starting ref: 12:33Z Version/JobModifyIndex values in the lane prompt (all matched at re-read — no other-writer drift, all Stop=false)
- Branch/worktree: none (live lane)
- Guidance: lane prompt STALEAUTH-LIVE2 (+ original STALEAUTH-LIVE prompt for method/rules); project AGENTS.md L1 informative only; reused prior lane's Step 0–1 (inventory not redone)
- Status: completed (`exit=0`; no commits; watcher untouched)

Persisted by the orchestrator from the lane hand-off (the lane could not commit its own journal). No wait was needed at persist time — the lane had already finished (`$S/STALEAUTH-LIVE2.out` contains `exit=0`).

## Timeline

- 12:36Z — Step 0: recall OK; all 9 in-scope Version/JobModifyIndex values match 12:33Z (Stop=false, auth still present); tunnel leader 200.
- Batch A (periodic/parameterized parents), all CAS-submitted with spec JobModifyIndex, all verified `auth present: false`, no running allocs disturbed: guard-heartbeat v3→v4 (12:38Z); keyround-periodic v5→v6 (12:39Z); remember-drain v15→v16 (12:40Z); cognee-ingest v3→v4, removed 2 (12:41Z); cognee-snapshot v0→v1 (12:42Z); keyround-manual v7→v8 (12:43Z, parameterized — fixed unproven until next dispatch); graph-prep-attempt v25→v26 (12:44Z, parameterized — same); ops-run v2→v3 (12:45Z, parameterized — same).
- 12:47Z — Batch B: cognee-alloy v9→v10 (1 removed, submit OK). First attempt conflicted: the strip script sent the response-header raft index (27881) instead of the spec JobModifyIndex (27875); re-read confirmed no other writer, resubmitted once with the spec index → http 200, v10 verified clean. 12:55Z: v10 healthy (alloc running 60 s+, 0 restarts, Received/Setup/Driver/Started, no pull errors; one 401-string was a namespace-timestamp false positive).
- Proofs via natural children (no force-launch, no dispatch): remember-drain v16 children (12:40/12:50/13:00Z) complete clean; keyround-periodic v6 13:00Z child pulled+running, no 401 (lane waited for the due run); guard-heartbeat v4 12:55Z child complete clean; traffic-count v3 children 12:40→13:00Z complete clean. Daily/parameterized jobs (cognee-ingest, cognee-snapshot, keyround-manual, graph-prep-attempt, ops-run): fixed, unproven until next run/dispatch. Skipped: none.
- 13:05Z — Read-only deferred check: cognee-blue v2 running (4 auth tasks, inline-auth-current: false); cognee v17 Stop=true dead (4 tasks, false); keeper-probe-shell v1 Stop=true dead (1 task, false). All three carry the OLD rotated password and break at rotation; blue runs on cached image only. (Compared in python memory via hmac.compare_digest; only booleans recorded.)
- 13:06Z — Step 5: `result.md` written; ONE #2438 comment (`issuecomment-5846510613`: done jobs + proofs, skipped none, deferred with reasons, two owner flags); leak-check clean; lesson saved to `agent-memory-ksonny4-platform`.

## Decisions

- cognee-blue / cognee / keeper-probe-shell never submitted: owned/stopped by another agent session (blue cut over 12:23Z) — read-only booleans only, per scope.
- traffic-count transient 401 window (12:35Z child, 5 pull-401s across 2 allocs, self-recovered; all later children first-try clean) reported as undetermined-cause flag, not a blocker — steady state proves clean pulls.
- CAS must use spec JobModifyIndex, never the X-Nomad-Index header (learned from the cognee-alloy conflict); live-API docker `auth` is a single-element LIST, not a bare map (detection/deletion unaffected).

## Artefacts changed

- Live: 9 jobs stripped (guard-heartbeat v4, keyround-periodic v6, remember-drain v16, cognee-ingest v4, cognee-snapshot v1, keyround-manual v8, graph-prep-attempt v26, ops-run v3, cognee-alloy v10) — all `auth present: false`
- `$S/staleauth/`: `strip_auth.py`, `result.md`, `comment-2438.md`, shared `progress.log` (per-job + proof lines)
- Issue comment polymarket-wallet-finder#2438 `issuecomment-5846510613`
- No commits; watcher untouched; wave-1 + keeper jobs untouched (deferred per scope)

## Checks and evidence

- Per-submit verify: `auth present: false` on the new version; running allocs unchanged; index-conflict path re-read once then resubmitted (cognee-alloy)
- Health/proof: cognee-alloy v10 60 s+ / 0 restarts / Started, no pull errors; 4 periodic parents PROVEN via natural children (complete, 0 restarts, 0 pull-fails)
- Read-only booleans: blue/cognee/probe-shell inline-auth-current all false
- Leak-check (vault-token prefix, long base64/hex runs, auth-block literals, password assignments, bearer tokens) on result.md + comment — clean

## Reflection and knowledge saved

- Recalled context: prior lane's inventory + regauth method; strip_auth.py reuse.
- Lesson / what worked: natural-child proofs (wait ≤15 min, never force-launch/dispatch) verify periodic strips without extra live action; header-index vs spec-index CAS distinction; auth-as-list shape note.
- Memory delivery: saved (lesson to `agent-memory-ksonny4-platform`, per lane report).

## Blockers / unresolved

- None in scope. Owner flags (in result.md + #2438 comment): (1) transient 12:35Z 401 window, cause undetermined — correlate with registry-side logs; (2) deferred jobs break at rotation (booleans above); wave-1 jobs await the watcher fix.
- Nothing merged (no commits by design).

## Handoff

- Final status: completed
- Remaining work: none for this lane (daily/parameterized proofs arrive with natural runs/dispatches)
- Next safe action: STALEAUTH-BLUE (cognee-blue strip) and STALEAUTH-REPO (repo PRs) run as separate lanes
- Authoritative references: `$S/staleauth/result.md` + `progress.log`; `$S/STALEAUTH-LIVE2.out` (`exit=0`); #2438 comment 5846510613
