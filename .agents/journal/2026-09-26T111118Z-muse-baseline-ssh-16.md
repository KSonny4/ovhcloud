# Agent journal: Slice N memory baseline via read-only SSH (BASELINE-SSH-16)

- Started: 2026-09-26 ~10:48 UTC (first sample 12:48 CEST); finished 2026-09-26T11:11:18Z UTC (lane report mtime)
- Agent/session: Meta Muse Spark (lane BASELINE-SSH-16)
- GitHub Issue(s): KSonny4/platform#16 (Slice N baseline)
- Task: lane prompt BASELINE-SSH-16 — STRICTLY READ-ONLY host measurement (owner approved 2026-09-26 12:46 CEST) because the Nomad stats API is empty: map containers to Nomad allocs/tasks, 3 samples ~10 min apart, apply the sizing formula exactly, write scratchpad JSON+MD, post ONE comment on #16; apply nothing to Nomad
- Intended outcome: a measurement-backed per-task sizing table with wave-1/wave-2 savings on issue #16
- Repository: KSonny4/platform (untouched)
- Starting ref: baseline join source `scratchpad/lanes/baseline/baseline.json` (BASELINE-16 output: reservations, memory_max, wave, restarts, OOM)
- Branch/worktree: none (all outputs under scratchpad `lanes/baseline-ssh/`)
- Guidance: lane order spec (allowed remote reads only: `docker ps`, `docker stats --no-stream`, `docker inspect` labels/name only, cgroup `memory.*` cats, `free -m`, `uptime`; no exec/stop/editing; no env/secret reads)
- Status: completed (table posted; wave-1 3792 MiB + wave-2 3568 MiB proposed; registry 256→128 rejected; nothing applied)

Persisted by the orchestrator from the lane hand-off (the lane could not commit its own journal).

## Timeline

- 12:48 / 12:58 / 13:09 CEST (~10:48/10:58/11:09 UTC) — Three read-only SSH samples (`ssh -i ~/.ssh/ovh_coolify_ed25519`, BatchMode; no sudo needed, no env read). Per task, anon = cgroup `memory.current − inactive_file + memory.swap.current`, plus lifetime `memory.peak` (minus latest cache as documented proxy). `docker stats` MemUsage matches anon within ~1 MiB on all 33 containers, confirming the join. 33 containers mapped via `<task>-<alloc_id>` names + `alloc_id` label (only Nomad label present); 4 bootstrap/init tasks have no container → skipped, no data. Local SSH tunnel (PID 66009) untouched and alive.
- 2026-09-26 ~11:10 UTC — Wrote `scratchpad/lanes/baseline-ssh/baseline.json` (37 rows, samples, peaks, proposals) and `baseline.md` (table + totals + registry note + anomalies), plus raw `sample{1,2,3}_{stats,cgroup}.txt` and `analyze.py`. Evidence files secret-scanned at persist time — clean (memory numbers, alloc IDs, job names only).
- 2026-09-26 — Posted ONE comment on KSonny4/platform#16 (no secrets/env): https://github.com/KSonny4/platform/issues/16#issuecomment-5845755623.

## Decisions

- Formula applied exactly (data, restated): `memory = max(64, ceil(max_obs*1.5/16)*16)` MiB; `memory_max = max(old memory, old memory_max, 2*new memory)`; skip if `old memory − new memory < 64` MiB; never shrink openbao; CPU unchanged. Wave assignment per lane: wave 1 = dump, jev-corpo-lint, graph-*, ge-night-master, keeper-staging, keeper-probe-shell, keeper-alloy, cognee-alloy, unleash, unleash-postgres, flags-*, cloudflared-unleash, tunnel-ge-edge (non-critical); wave 2 = cognee-blue, control-panel, keeper, rustfs, registry, edge-proxy; trading-namespace `dom.ops-serve` skipped (out of scope); openbao never.
- Registry 256 → 128 NOT supported — observed ~148 MiB > 128; keep 256.
- Near/at-cap tasks kept at current reservation despite formula output: `mcp` 448 (352 MiB steady, 79%, peak exactly at cap — keep, consider raising); `shell` 1024 (6.6 MiB samples but lifetime peak exactly at cap — keep); `zencli` 1024 (peak 779/1024, spiky — keep); `zlight-a1a745de` 768 (peak 740/768, 96% — keep).
- `dump/app` 512 → 272 proposed (peak at cap but oom=0, cache-heavy) with noted residual risk — operator may hold 512.
- Only a short summary is recorded here, not the raw per-task table: `.agents/journal` is the place for the summary; the full table lives in the scratchpad evidence (`lanes/baseline-ssh/baseline.md`) and the issue comment.

## Artefacts changed

- (No repo changes; nothing applied to Nomad.) Scratchpad: `lanes/baseline-ssh/{baseline.json,baseline.md,issue-comment.md,analyze.py,sample{1,2,3}_{stats,cgroup}.txt}`.
- Issue comment 5845755623 on KSonny4/platform#16.

## Checks and evidence

- Totals: wave-1 saving 3792 MiB (~3.70 GiB), 17 shrinks; wave-2 saving 3568 MiB (~3.48 GiB: cognee-server 6144→4128, control-panel 512→80, keeper-server 512→128, rustfs 1024→288); combined 7360 MiB (~7.19 GiB); running reservations would fall ~19240 → ~11880 MiB.
- Node `free -m`: available 16905 → 16723 MiB across samples; swap 3/2047 used — no memory pressure.
- Anomalies: `cognee/server` anon grew 2585 → 2737 MiB in 20 min on a 27-min-old container — re-measure in 24 h; `worker` idle at 0.45 MiB → 64.

## Reflection and knowledge saved

- Recalled context: not recorded in the hand-off.
- Lesson / what worked: cgroup `memory.current − inactive_file + swap.current` cross-checked against `docker stats` (±1 MiB) is a workable read-only substitute when the Nomad stats pipeline is empty; lifetime `memory.peak` catches spiky tasks that point samples miss (mcp/shell/zencli keeps).
- Memory delivery: not recorded in the hand-off for this lane.

## Blockers / unresolved

- None in lane scope. Open follow-ups (not this lane): re-measure `cognee/server` in 24 h; operator call on `dump/app` 512 vs 272 and on raising `mcp` above 448.

## Handoff

- Final status: completed (read-only; no Nomad writes)
- Remaining work: none in this lane (apply/watch is the WAVE1-16 lane)
- Next safe action: wave-1 sizing lane consumes the posted table
- Authoritative references: issue comment 5845755623; scratchpad `lanes/baseline-ssh/{baseline.json,baseline.md}`
