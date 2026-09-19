# Engineering guidance adoption (this repo's overlay)

Adopted revision: `KSonny4/engineering-guidance@474b8c21108d06309c6dde6bd492f200779a84e4`
(PR #58 merge, 2026-09-16, "Services use our domains with the container platform as primary target",
closes issue #57; docs-only guidance change, no runtime effect).
Previous pin: `656d5569f261afb75f7c7685bea55e1e71518f9b`.
Files loaded at adoption: `AGENTS.md` plus task-triggered playbooks
(operations, secrets, orchestration as triggered) at the adopted revision.

## What PR #58 changed (upstream)

- `docs/secrets-usage.md`: Bao primary transport is `https://secrets.pkubelka.cz`
  (local OpenBao proxy stays valid where configured on a consuming host — an
  alternative bound address, not a second contract). AppRole authentication
  precedes kv reads. Upstream promotes its default container platform to
  primary deploy target; webhook wiring is HITL with
  `gh api .../hooks/<id>/deliveries` verification. Upstream names
  platform secret→container-env injection as an authorised edge (never
  printed/logged/persisted; rotation triggers redeploy/restart).
- Upstream's new one-service pattern doc: portable one-service pattern with
  AFK (agent-runnable, exact command + done-check) vs HITL (human-only,
  checklist + resume condition) legend; `$PORT` listener, `/healthz`,
  env/secrets, volumes, TLS via platform domains, logs, redeploy/rollback.
- `standards/secrets.md`, `standards/stack.md`, `standards/operations.md`:
  domain-primary transport wording, platform-primary pointer, platform env
  edge.

> Divergence (2026-09-18, this overlay): upstream's default deploy target
> is NOT adopted here. This repo deploys to Nomad only (`docs/03-nomad.md`);
> the retired control plane's dashboard/API patterns below are superseded
> by the Nomad procedure.
- Intentional loopback left upstream in tunnel-pattern/outcomes/baseline
  (origin/exporter endpoints) — not drift.
- The pointer alone grants no deploy authority; `authority.md` + overlay scope
  still decide. Upstream notes this Mac has no local proxy (`:8100`/`:8200`
  refused) — operational follow-up outside guidance.

## This repo's mapping (already aligned, verified 2026-09-17; cutover deltas verified 2026-09-19)

- Transport: scripts default to `BAO_ADDR=https://secrets.pkubelka.cz`
  (`verify-nomad-live.sh`, `fetch-r2-env.sh`);
  no `127.0.0.1:8100`/`:8200` consumer usage anywhere (`rehearsal.invalid` is
  test-stub addressing, not transport). No wording drift; no runbook changes.
- Deploy target: Nomad only at `https://nomad.pkubelka.cz`
  (Access OTP `ksonny4@gmail.com` — human login verified 2026-09-19 on the
  cutover tunnel; machine path via escrowed service token). One job per
  deployable (`edge-proxy`, `registry:2` per `docs/09-docker-registry.md`,
  `cognee` vendored from `KSonny4/cognee-setup` per `docs/11-cognee.md`)
  via `nomad job run`. OmniRoute/Fabric retired, never migrated.
- Plane topology since 2026-09-19: new VPS `vps-c85da816.vps.ovh.ca`
  (148.113.245.89, BHS6) serves nomad/ssh/registry/cognee through dedicated
  tunnel `nomad-148-113-245-89`; the preserved tunnel + old VPS keep the
  un-migrated workloads (keeper/dump/graph-dispatcher). Old-cluster ACL
  token rescued to `NOMAD_BOOTSTRAP_PRESERVED` (runner `kv put` clobber
  incident — runner now merges, never replaces).
- Secrets edge: OpenBao escrow by name only (`docs/iac-interfaces.md`
  inventory); Nomad `-var-file`/stdin-pipe rendering at the deploy edge
  (never `template`-stanza values in specs); presence-only verification,
  values never in Git/prompts/logs. Rotation per `docs/secret-rotation.md`.
  Service-token OBJECT is API/OpenBao-managed (provider version trap —
  Terraform binds `var.access_service_token_id` in app policies only).
  `backup-r2-reader` policy covers both `ovhcloud/*` and `nomad/*` paths.
- Healthchecks: TCP service checks (auth-gated endpoints 401 anonymous
  callers); registry proven by anon-401 + authenticated catalog/push/pull,
  cognee edge by anon-401 + `cognee edge ok` + MCP/REST smokes; public-hostname
  verification, never origin ports (tunnel-only invariant, `CONTEXT.md`).
  The cognee image HEALTHCHECK targets static :8000 while the job binds a
  dynamic port — structurally unhealthy, excluded from the live gate by name
  with the smokes as real proof.
- Dynamic-port discipline: the cognee edge takes a scheduler-assigned
  loopback port, so every redeploy must re-point the tunnel ingress rule
  AND the matching Terraform line, or the hostname 404s. Bulk image pushes
  bypass the ~100MB edge cap via loopback (`registry_http_host` override,
  then redeploy with the default).

## Deploy procedure for later (condensed, this overlay)

1. AFK repo-side: app listens on `$PORT`, exposes health endpoint, Dockerfile
   pins digest; local `curl localhost:$PORT/<health>` → 200 before deploy.
2. AFK deploy: `nomad job run jobs/<app>.nomad.hcl` with domain
   `<app>.pkubelka.cz`, env/secrets (OpenBao-rendered), volume mounts,
   limits. Resume facts: job name, jobspec SHA, allocation ID, public hostname.
3. Secrets: values rendered from OpenBao escrow by name at deploy time;
   agent verifies presence-only, never values.
4. Terraform (operator, authorized apply only): DNS CNAME + tunnel ingress per
   `docs/deployment-plan.md`; `terraform plan` must show ONLY the intended
   adds/changes (imports first for API-created objects), and a second plan
   must be empty after apply.
5. AFK verify: `curl https://<host>/<health>` → 200; webhook deliveries via
   `gh api repos/<owner>/<repo>/hooks/<id>/deliveries`; record SHA + build id.
6. Rollback: `nomad job revert` to the prior known-good version, re-run step 5.
