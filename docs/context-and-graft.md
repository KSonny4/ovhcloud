# Context and graft workflow

`CONTEXT.md` is the short architectural contract for this repository. It defines the provider boundary, public-edge invariant, secret ownership, recovery expectations and deployment vocabulary. Read it before changing IaC or runbooks.

## Rebuild and verify

From the repository root:

```bash
graft build
graft check
graft ask "where is the OVH and Cloudflare deployment boundary?"
```

`graft build` is local, deterministic wiring/index generation and does not apply infrastructure. `graft check` fails when the graph is stale. The generated `graft/.cache/` and `graft/.graph/` directories are local and ignored; the tracked `graft/INDEX.md` is the lightweight entry point.

Use the context contract and the deployment plan together:

1. Read `CONTEXT.md` and `docs/deployment-plan.md`.
2. Run `graft ask` before locating a change in an unfamiliar subsystem.
3. Make the smallest source/runbook/IaC change that preserves the invariants.
4. Rebuild and check graft after source changes.
5. Run `bash scripts/validate-repository.sh` before review.

Graft is an index and navigation aid, not a secrets store, Terraform state backend, issue tracker, or substitute for provider-aware validation.
