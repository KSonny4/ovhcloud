# Fresh-environment edge module

This root module adopts the Cloudflare edge created by the fresh runner path
(`scripts/wire-fresh-edge.sh --handoff-file`) into Terraform state. Nothing
here is hand-authored per environment: `main.tf` + `imports.tf` are GENERATED
by `scripts/emit-fresh-imports.sh --handoff <file>` (both gitignored), using
the same provider resources and conventions as `infra/terraform/main.tf`
(nested Access policies, `non_identity` machine decision, `http_status:404`
catch-all). The shared machine service token is referenced by ID only, never
managed here; the VPS itself stays runner-managed.

Adoption (no manual blocks):

```bash
bash scripts/adopt-fresh-edge.sh --handoff <handoff-json>   # generate + plan
bash scripts/adopt-fresh-edge.sh --handoff <handoff-json> --apply  # adopt + converge
```

`terraform plan` must end with no changes once the import blocks are applied.
