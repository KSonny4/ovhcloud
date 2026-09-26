# Agent journal: strip stale inline registry auth from live cognee-blue (STALEAUTH-BLUE)

- Started: 2026-09-26T12:55:12Z UTC (progress.log step0); finished 2026-09-26T13:06:04Z UTC (last progress.log line; lane .out `exit=0`)
- Agent/session: Meta Muse Spark (lane STALEAUTH-BLUE)
- GitHub Issue(s): KSonny4/polymarket-wallet-finder#2438
- Task: lane prompt STALEAUTH-BLUE — owner approval 2026-09-26 ~14:48 CEST ("Strip now"): remove ONLY the docker `auth` key from the LIVE cognee-blue task configs, one redeploy, health-checked; revert to previous version and STOP if not healthy within 10 min.
- Intended outcome: cognee-blue pulls via node-level auth; stays healthy; #2438 comment + result.md; no other job touched
- Repository: none written (no Git commits per hard rules); live job cognee-blue only
- Starting ref: cognee-blue v2, JobModifyIndex 103577 (preflight-verified; no other writer — versions list only 0/1/2, unmodified after 13:05Z)
- Branch/worktree: none (live lane)
- Guidance: lane prompt STALEAUTH-BLUE (+ STALEAUTH-LIVE2 method: spec JobModifyIndex for CAS, never the header); project AGENTS.md L1 informative only; one Cognee recall (cognee-blue deployment/health) + `$S/staleauth/progress.log` + `strip_auth.py` reuse
- Status: completed — strip SUCCESS, no revert (`exit=0`)

Persisted by the orchestrator from the lane hand-off (the lane could not commit its own journal).

## Timeline

- 12:55:12Z — Step 0: Cognee recall (15 hits via MCP); staleauth progress.log + strip_auth.py read; tunnel 200.
- 12:57:08Z — Step 1 preflight (all STOP conditions held → proceeded), recorded to `before.md`: namespace default, Version 2, JobModifyIndex 103577, Status running, Stop=false; 4 tasks carry `auth` (names only); images digest-pinned (caddy + cognee:1.6.1/cognee-mcp:1.6.1), force_pull unset; update stanza (MaxParallel=1, Canary=0, AutoRevert=false, Stagger=30s); running alloc 4e10a72c (server/mcp/edge running, 0 restarts; bootstrap dead exit 0); no running deployment (v1+v2 deployments successful); health endpoint → 200; Cognee recall works.
- 12:57:44Z — Step 2: read live spec via API; deleted ONLY `Config.auth` from 4 task configs (cognee/bootstrap, cognee/server, cognee/mcp, cognee/edge) in memory; diff-asserted only-auth-removed=true (removed=4, diff_paths=4); CAS-submitted with body JobModifyIndex=103577 (eval 350a2189); verified v3 `auth present: false`. Spec with auth never written, printed, or diffed.
- 13:05:20Z — Step 3 health (10-min budget, no revert): deployment v3 successful; new alloc 1041d82e running, 0 restarts, 4 Started events, 0×401, 0 pull errors. Direct `/health` → 200 (×2, ready/healthy v1.6.1); `/docs` → 200; `/api/*` → 401 (auth challenge = full stack alive). Authenticated end-to-end search (same shape/auth as cognee-guard) → 200 with 2 results via both new edge and server tasks (temporary local SSH forward, removed after).
- Incident note (facts from lane report): public `https://cognee.pkubelka.cz/*` → 502 through the whole window — proven ingress-layer (outside the job, outside approval): v3 stack healthy end to end, service discovery correct, old edge port closed. Revert rotates dynamic ports again and cannot restore the public route while reintroducing stale auth, so revert was deliberately WITHHELD per "STOP and report instead of improvising"; routing-owner follow-up recorded in the issue. No agent restarts, no config/Bao/registry/Git changes, no other job touched.
- 13:06:04Z — Step 4: ONE #2438 comment (`issuecomment-5846507343`, secret-scanned clean); `result.md` written; lesson saved via `cognee-guard remember` (no secret values).

## Decisions

- Proceeded past preflight only because every STOP condition held (version, health, allocs, no other writer).
- Withheld the revert for the public-502 (ingress-layer, unfixable by revert, revert reintroduces stale auth) — reported instead of improvising, per hard rules.
- Self-reported hygiene incident: one early `bao kv get` without `-field` printed the read token to the lane's buffered stdout only — never written to any file, log, or comment; all subsequent reads used `-field` into env. No values in any artefact.

## Artefacts changed

- Live: cognee-blue v2→v3 (only change: 4× `auth` key removed; images, resources, env, templates, services, update stanza, counts, constraints, meta unchanged)
- `$S/staleauth-blue/`: `progress.log` (5 lines), `before.md`, `result.md`, `issue_comment.txt`, `submit_ts.txt`, `watch.log`, scripts (`preflight.py`, `alloc_detail.py`, `strip_blue.py`, `watch.py`, `e2e_search.py`)
- Issue comment polymarket-wallet-finder#2438 `issuecomment-5846507343`
- No commits; no restarts/config/Bao/registry changes.

## Checks and evidence

- In-memory diff-assert (only-auth-removed=true) + CAS with spec JobModifyIndex → eval 350a2189; v3 `auth present: false`
- Deployment successful; alloc 1041d82e 0 restarts / 4 Started / 0×401 / 0 pull errors; `/health` 200 ×2; e2e recall 200 with results
- Secret-scan before posting — clean; no secrets printed, logged, or posted (one buffered-stdout-only exception above, contained)

## Reflection and knowledge saved

- Recalled context: cognee-blue deployment/health recall + STALEAUTH-LIVE2 strip method (spec-index CAS).
- Lesson / what worked: preflight STOP-gates + diff-assert + narrow revert budget make a live-auth strip on the production Cognee safe; public-URL health is not job health — verify at the task/service-discovery layer before blaming the deploy.
- Memory delivery: saved (via `cognee-guard remember`, per lane report).

## Blockers / unresolved

- Public `cognee.pkubelka.cz` 502 (ingress-layer) — routing-owner follow-up open (repoint the public forward at the current edge port); not this lane's scope.
- Nothing merged (no commits by design).

## Handoff

- Final status: completed
- Remaining work: none for this lane
- Next safe action: routing owner fixes the public forward; repo-side auth removal continues in STALEAUTH-REPO
- Authoritative references: `$S/staleauth-blue/result.md` + `progress.log` + `before.md`; `$S/STALEAUTH-BLUE.out` (`exit=0`); #2438 comment 5846507343
