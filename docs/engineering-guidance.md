# Engineering guidance adoption (this repo's overlay)

Adopted revision: `KSonny4/engineering-guidance@474b8c21108d06309c6dde6bd492f200779a84e4`
(PR #58 merge, 2026-09-16, "Services use our domains with Coolify as primary target",
closes issue #57; docs-only guidance change, no runtime effect).
Previous pin: `656d5569f261afb75f7c7685bea55e1e71518f9b`.
Files loaded at adoption: `AGENTS.md` plus task-triggered playbooks
(operations, secrets, orchestration as triggered) at the adopted revision.

## What PR #58 changed (upstream)

- `docs/secrets-usage.md`: Bao primary transport is `https://secrets.pkubelka.cz`
  (local OpenBao proxy stays valid where configured on a consuming host — an
  alternative bound address, not a second contract). AppRole authentication
  precedes kv reads. Coolify promoted from owner-default to primary deploy
  target; webhook wiring is HITL with `gh api .../hooks/<id>/deliveries`
  verification. Coolify secret→container-env injection named as an authorised
  edge (never printed/logged/persisted; rotation triggers redeploy/restart).
- `docs/coolify-service.md` (new): portable one-service pattern with AFK
  (agent-runnable, exact command + done-check) vs HITL (human-only, checklist +
  resume condition) legend; `$PORT` listener, `/healthz`, env/secrets,
  volumes, TLS via Coolify domains, logs, redeploy/rollback.
- `standards/secrets.md`, `standards/stack.md`, `standards/operations.md`:
  domain-primary transport wording, Coolify primary pointer, Coolify env edge.
- Intentional loopback left upstream in tunnel-pattern/outcomes/baseline
  (origin/exporter endpoints) — not drift.
- The pointer alone grants no deploy authority; `authority.md` + overlay scope
  still decide. Upstream notes this Mac has no local proxy (`:8100`/`:8200`
  refused) — operational follow-up outside guidance.

## This repo's mapping (already aligned, verified 2026-09-17)

- Transport: scripts default to `BAO_ADDR=https://secrets.pkubelka.cz`
  (`ensure-omniroute-secrets.sh`, `verify-coolify-live.sh`, `fetch-r2-env.sh`);
  no `127.0.0.1:8100`/`:8200` consumer usage anywhere (`rehearsal.invalid` is
  test-stub addressing, not transport). No wording drift; no runbook changes.
- Deploy target: Coolify primary at `https://coolify.pkubelka.cz`
  (Access OTP `ksonny4@gmail.com`); project `context-fabric` (preserved),
  `production` environment; one service per deployable (`fabric`, OmniRoute,
  `registry:2` per `docs/09-docker-registry.md`).
- Secrets edge: OpenBao escrow by name only (`docs/iac-interfaces.md`
  inventory); Coolify env/file-mount injection; presence-only verification,
  values never in Git/prompts/logs. Rotation per `docs/secret-rotation.md`.
- Healthchecks: `/health` (registry), app-owned endpoints; public-hostname
  verification, never origin ports (tunnel-only invariant, `CONTEXT.md`).

## Deploy procedure for later (condensed, this overlay)

1. AFK repo-side: app listens on `$PORT`, exposes health endpoint, Dockerfile
   pins digest; local `curl localhost:$PORT/<health>` → 200 before deploy.
2. HITL dashboard: project → `production` → New Resource (Docker Image or Git
   repo); set domain `<app>.pkubelka.cz`, env/secrets, volume mounts, limits.
   Resume facts: service name, repo+branch, app UUID, public hostname.
3. HITL secrets: values entered in Coolify (sourced from OpenBao escrow by
   name); agent verifies presence-only, never values.
4. Terraform (operator, authorized apply only): DNS CNAME + tunnel ingress per
   `docs/deployment-plan.md`; `terraform plan` must show adds only.
5. AFK verify: `curl https://<host>/<health>` → 200; webhook deliveries via
   `gh api repos/<owner>/<repo>/hooks/<id>/deliveries`; record SHA + build id.
6. Rollback: redeploy prior known-good SHA/image, re-run step 5.
