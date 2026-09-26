# Agent journal: home Nomad clients as code (lane PI-P)

- Started: 2026-09-26T13:11Z
- Agent/session: Meta Muse Spark (lane PI-P)
- GitHub Issue(s): KSonny4/platform#27
- Task: Slice P steps 1, 2, 5 (repo part) — ZeroTier network ADR, host inventory, Pi + Fujitsu client configs, dry-run provision script, contract tests
- Intended outcome: reviewable PR with client config as code; the live join ([YES]) is explicitly out of scope
- Repository: KSonny4/platform
- Starting ref: origin/master f5e7e56
- Branch/worktree: feat/nomad-home-clients-pi-p (.worktrees/pi-p, single writer)
- Guidance: platform AGENTS.md + CONTEXT.md; engineering-guidance core + outcome-reporting, agent-journal (adopted 474b8c21 per project AGENTS.md)
- Status: active

## Timeline

- 2026-09-26T13:10Z — Cognee recall attempted on the lane topic; backend returned MCP 502 (unavailable, not a no-match). Proceeding per guard rule; secret values stay out of Cognee either way.
- 2026-09-26T13:11Z — Read plan Slice P + owner decisions (12:06 CEST: Fujitsu joins), engineering-guidance AGENTS.md, outcome-reporting, agent-journal standards.
- 2026-09-26T13:12Z — Created worktree off origin/master; created issue #27 with objective + acceptance checks.
- 2026-09-26T13:1xZ — Sourced facts read-only: server config `config/nomad.hcl` + `scripts/provision-nomad.sh` conventions (Nomad 2.0.6 default, gossip file, unit shape); Pi `ip rule` pinning from automatization `scripts/cloudflared-tunnel-guard.sh` (pref 1, `to <prefix> lookup main`) + CLAUDE.md (`ssh pi@172.23.215.6`); Fujitsu from polymarket-wallet-finder CLAUDE.md (`ssh ksonny@172.23.229.176`) and docs/DECISIONS.md (i5-8400T 6c, 15 GB, ~7.7 GB unreserved, recorder ~4.9 GB).

## Decisions

- Inventory is `config/clients/inventory.json` (JSON so both bash via python3 and the unittest read it); `nomad_version` there is the one place, with a test pinning it to the `provision-nomad.sh` default.
- OVH ZeroTier IP, ZeroTier managed-route CIDR, and Fujitsu's exact Ubuntu release are `TODO(owner)` placeholders — observed but unsourced, never invented.
- Did NOT extend `scripts/validate-repository.sh` (shared gate file, other lanes active); new-script coverage is via manual `bash -n`/shellcheck + the unittest instead.

## Artefacts changed

- docs/adr/0001-zerotier-nomad-clients.md
- config/clients/inventory.json, config/clients/pi.hcl, config/clients/fujitsu.hcl
- scripts/provision-client.sh (chmod +x)
- tests/test_nomad_clients.py
- .agents/journal/2026-09-26T131500Z-meta-muse-spark-pi-p-home-clients.md (this file)

## Checks and evidence

- Pending: new unittest, `bash scripts/validate-repository.sh`, `bash -n`/shellcheck, `git diff --check`, secrets grep.

## Reflection and knowledge saved

- Recalled context: none delivered (Cognee MCP 502 at session start).
- Lesson candidate: derive-everything-from-inventory + placeholder-equality tests let TODO(owner) values stay consistent across HCL/JSON without inventing facts. Save via `cognee-guard remember` at session end if delivery works.

## Blockers / unresolved

- Live join (Slice P step 3 [YES]) not in this lane; client configs ship with the OVH `retry_join` placeholder until the owner puts the host on ZeroTier.
