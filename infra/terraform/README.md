# OVH + Cloudflare Terraform

This root module models the deployment boundary without performing a live apply.

## What it manages

- OVH VPS ordering when explicitly enabled, or read-only discovery of an existing VPS when `provision_ovh_vps = false`; the current provider exposes the purchase plan, while OS/key bootstrap remains an explicit operator gate.
- Cloudflare DNS records for the Nomad UI, SSH Tunnel hostname, adopted app hostnames (`fabric`, `omniroute`, `omni`, plus plan-only `registry`), and optional application wildcard.
- Cloudflare Tunnel ingress from `ssh.<domain>` to `localhost:22`, UI to `localhost:4646`, and app hostnames to `localhost:80`.
- Cloudflare Access policies for the Nomad UI and SSH, limited to `admin_emails`.
- A private Cloudflare R2 bucket for backup destinations.

The application deployment remains in Nomad jobs. Terraform does not create application databases, OmniRoute secrets, Nomad bootstrap material, R2 access keys, or private SSH keys.

## Operator workflow

1. Install Terraform >= 1.6 and the pinned providers.
2. Provider authorization comes only from the environment via `scripts/tf-env-from-openbao.sh` (OpenBao + read-only OVH discovery, eval its output). No `terraform.tfvars` file is ever written — an earlier file-writing loader proved any on-disk copy leaks through tooling.
3. Provider authorization is OpenBao-only: the loader in step 2 pulls the Cloudflare account/zone IDs (constants defaulted, overridable) and the least-privilege API token from the existing OpenBao instance — no external secret manager, profile, or credential file participates.
4. `terraform.tfvars.example` documents the variable set for reference only; live values always arrive as `TF_VAR_*` env from the loader script above.
5. Run `terraform fmt -check main.tf versions.tf variables.tf outputs.tf`, `terraform init -backend=false`, and `terraform validate` (scope fmt to tracked files; `-recursive`/`-diff` would print secrets from ignored credential files).
6. For an authorized production plan, copy `backend.hcl.example` to ignored `backend.hcl` and run `terraform init -backend-config=backend.hcl`; copy confirmed `imports.tf.example` blocks to ignored `imports.tf` before the first import plan, then delete `imports.tf` after the imports are recorded. Local state is allowed only for a disposable rehearsal directory.
7. After any live-backend operation, restore credential-free gates before running repo checks: `rm -rf infra/terraform/.terraform && terraform -chdir=infra/terraform init -backend=false -input=false`. A backend-bound `.terraform/` makes `validate-repository.sh` and the rehearsal fail (they require no live credentials). Never run bare `terraform fmt -recursive`/`-diff` where ignored credential files live; scope fmt to named `.tf` files.
8. Fresh hosts are bootstrapped noninteractively with `scripts/bootstrap-vps.sh`; the preserved VPS is never a bootstrap target.
9. Keep `provision_ovh_vps = false` for the existing origin. The read-only `ovh_vps.existing` data source verifies it; do not set `provision_ovh_vps = true` unless ordering a new VPS was explicitly approved and payment consequences are understood.
10. Run and review `terraform plan`. A human must authorize any `terraform apply`.

Provider credentials are read from the Terraform variables/provider environment and must never be stored in this directory. Terraform state contains sensitive provider and Tunnel material; production state must not remain local or unencrypted.

## Safe local checks

From the repository root:

```bash
python3 scripts/validate-iac.py
bash scripts/validate-repository.sh
```

With Terraform installed:

```bash
terraform fmt -check -recursive
terraform init -backend=false -input=false
terraform validate
```

No check in this repository runs `terraform apply` or mutating `ovhcloud` commands.
