# Agent journal: record OVH ZeroTier join, fill client inventory (lane ZT-INVENTORY)

- Started: 2026-09-26T15:28Z
- Agent/session: Meta Muse Spark (lane ZT-INVENTORY)
- GitHub Issue(s): KSonny4/platform#27
- Task: Record the owner-joined OVH ZeroTier membership as code; fill the three TODO(owner) placeholders in config/clients/inventory.json; mirror into *.hcl; add idempotent scripts/provision-zerotier.sh + tests; document the join in ADR 0001
- Intended outcome: reviewable PR against master (Refs #27); orchestrator merges. No live action of any kind.
- Repository: KSonny4/platform
- Starting ref: origin/master 4931549
- Branch/worktree: feat/zerotier-ovh-27 (.worktrees/zt-ovh-27, single writer)
- Guidance: platform AGENTS.md + CONTEXT.md; engineering-guidance adopted 474b8c21 per project AGENTS.md (AGENTS.md + CONTEXT.md read; operations, secrets, orchestration playbooks not triggered — no live action, no credentials)
- Status: complete — PR open, awaiting orchestrator merge

## Timeline

- 2026-09-26T15:28Z — Cognee recall on the lane topic (15 memories, incl. PI-P placeholder-equality convention); read AGENTS.md, CONTEXT.md, ADR 0001, inventory.json, both HCLs, provision-client.sh, test_nomad_clients.py, validate-repository.sh, CI workflow.
- 2026-09-26T15:28Z — Created worktree off origin/master (branch feat/zerotier-ovh-27).
- 2026-09-26T15:3xZ — Filled inventory.json (server_join_ip 172.23.6.223, zerotier_prefix 172.23.0.0/16, fujitsu os Ubuntu 24.04.4 LTS, each with fact+date source; factual server_join_ip_note; new zerotier_network_id + top-level server object); mirrored retry_join into pi.hcl/fujitsu.hcl with factual comments.
- 2026-09-26T15:3xZ — Added scripts/provision-zerotier.sh (chmod +x) + tests/test_provision_zerotier.py; full suite 51 tests OK; shellcheck + bash -n clean.
- 2026-09-26T15:3xZ — ADR 0001 "OVH joined" section (date, address, manual authorize, verification, rollback, two [YES] follow-ups, #36 pointer).
- 2026-09-26T15:3xZ — Gates: validate-repository.sh passed (incl. terraform validate + graft check OK), git diff --check clean, leak-grep clean (0 matches).

## Decisions

- New keys use the file's existing `*_source` convention (server_join_ip_source, zerotier_prefix_source, os_source, zerotier_network_id_source), each citing fact number + 2026-09-26 date.
- The `server` object is top-level, NOT inside `hosts` — the contract test builds one HCL path per `hosts` entry, so nesting it there would demand a server.hcl that does not exist.
- provision-client.sh untouched: it reads nomad_version/arch/zerotier_ip, none of which changed shape.
- Followed the PI-P precedent: did NOT extend scripts/validate-repository.sh (shared gate file, other lanes active); the new script is covered by bash -n/shellcheck (manual) + the new unittest.
- provision-zerotier.sh refuses a non-16-hex network ID (fail closed if inventory ever regresses to a placeholder) and never touches Nomad/ufw/Docker (asserted in tests on stripped source).

## Artefacts changed

- config/clients/inventory.json, config/clients/pi.hcl, config/clients/fujitsu.hcl
- scripts/provision-zerotier.sh (new, +x)
- tests/test_provision_zerotier.py (new)
- docs/adr/0001-zerotier-nomad-clients.md
- .agents/journal/2026-09-26T153040Z-meta-muse-spark-zt-inventory.md (this file)

## Checks and evidence

- `/opt/homebrew/bin/python3.14 -m unittest discover -s tests -v`: 51 tests, OK (43 existing + 8 new; no test removed or weakened).
- `bash scripts/validate-repository.sh`: passed (terraform validate + graft check OK).
- `bash -n` + `shellcheck` on scripts/provision-zerotier.sh: clean.
- `git diff --check`: clean.
- Leak-grep on full diff: 0 matches (exit 1).

## Reflection and knowledge saved

- Recalled context: PI-P placeholder-equality convention (TODO(owner) in JSON mirrored verbatim by HCL, contract-tested) — extended here to sourced values with `*_source` provenance notes.
- Lesson saved via cognee-guard remember at session end (ZeroTier join facts + manual-Central-authorize + loopback-bound Nomad).

## Blockers / unresolved

- None in scope. Merge is the orchestrator's. Follow-ups live with the owner: (a) Nomad RPC/serf bind to zt + ufw `allow in on zt+` [YES]; (b) Docker default-address-pools pin [YES].
