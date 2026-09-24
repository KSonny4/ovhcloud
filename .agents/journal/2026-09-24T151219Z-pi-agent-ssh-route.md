# Agent journal: agent SSH route docs

- Started: 2026-09-24T15:12:19Z
- Agent/session: pi / agent-ssh-route
- GitHub Issue(s): KSonny4/ovhcloud#10
- Task: Document direct-SSH agent route in docs/04-cloudflare.md so agents stop blocking on tunnel-SSH Access auth
- Intended outcome: section 2 teaches tunnel SSH = human path, direct SSH = agent path with derive-not-guess primary rule
- Repository: KSonny4/ovhcloud
- Starting ref: 48d6840
- Branch/worktree: fix/agent-ssh-route-10 (single writer)
- Guidance: ovhcloud AGENTS.md + CONTEXT.md; engineering-guidance core + outcome-reporting, context, operations, secrets, cognee-memory (adopted 474b8c21)
- Status: active

## Timeline

- 2026-09-24T15:12Z — Created issue #10. Branch cut from 48d6840.
- Live evidence reused from same-day probes (engineering-guidance#120): ssh.pkubelka.cz :22 timeout / :443 302 Access login; 57.129.155.203:22 timeout (STOPPED); 148.113.245.89:22 open; nomad.pkubelka.cz 302 Access. No secret values touched.

## Decisions

- Docs-only fix in 04-cloudflare.md section 2; no tunnel/DNS/Access mutation, no apply. Tunnel-route liveness on the new box stays an open verification item in the issue.
- Direct-SSH IP kept as labelled observed fallback with derive-from-overlay/OVH-API rule (no hard-coded permanent inventory).

## Artefacts changed

- docs/04-cloudflare.md (section 2 + Done-when)

## Checks and evidence

- Pending: repo gate + git diff --check

## Reflection and knowledge saved

- Recalled context: engineering-guidance lesson nomad-ssh-route-2026-09-24 (verified full-text recall) + fleet-migration + nomad-access-update memories.
- Lesson: ovhcloud architecture is tunnel-first by design (CONTEXT.md), so the fix is additive (agent route) not a rewrite — contradicting the owning design would be wrong scope.
- Memory delivery: no-new-learning (reuses nomad-ssh-route-2026-09-24; repo-specific pointer only)

## Blockers / unresolved

- Tunnel ssh-ingress liveness on vps-c85da816 unverified from here (needs box/API access with credentials).

## Handoff

- Final status: active
- Remaining work: edit, checks, commit, PR, merge per owner instruction
- Authoritative references: issue #10; engineering-guidance#120/#121
