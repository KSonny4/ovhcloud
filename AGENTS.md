# ovhcloud — agent instructions

Source of truth for the OVHcloud VPS deployment runbook is [CONTEXT.md](CONTEXT.md);
infra plan under `infra/terraform` (reviewable, non-live by default), scripts under `scripts/`.
Local entrypoints: `python3 scripts/validate-iac.py`, `bash scripts/validate-repository.sh`,
`graft check .`. A provider `apply` requires encrypted state, external credentials, an
approved domain and operator authorisation — never apply from an adoption task.

## Shared Engineering Guidance (prepare-only, L1 informative)

Profile: platform-security / L1 informative (hosting platform runbook).
Adopted revision: `KSonny4/engineering-guidance@656d5569f261afb75f7c7685bea55e1e71518f9b`
(reviewed merge, main). Load `AGENTS.md` plus task-triggered playbooks (operations, secrets,
orchestration as triggered) at that revision; record files actually loaded.
Existing active sessions keep their valid pins.

Context Fabric (interface v0.1 PROPOSED — pending, not active): no endpoint is configured,
no registration or indexing is claimed. When a published runtime exists, search is optional
and authenticated; mandatory guidance above never depends on it. Private deployment
particulars stay out of public Git. Graft: checkout-local only; a graph is not runtime state.

Adoption record: prepared 2026-09-14 (branch `pi/fabric-p3-prepare`); adopted/loaded/indexed/
verified pending shared runtime publication (P4) and P6 activation.
