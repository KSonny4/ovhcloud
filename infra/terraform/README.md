# OVH + Cloudflare Terraform

This root module models the deployment boundary without performing a live apply.

## What it manages

- OVH VPS ordering when explicitly enabled, or read-only discovery of an existing VPS when `provision_ovh_vps = false`; the current provider exposes the purchase plan, while OS/key bootstrap remains an explicit operator gate.
- Cloudflare DNS records for the Coolify dashboard, approved application wildcard, and SSH Tunnel hostname.
- Cloudflare Tunnel ingress from `ssh.<domain>` to `localhost:22`.
- Cloudflare Access policies for the Coolify dashboard and SSH, limited to `admin_emails`.
- A private Cloudflare R2 bucket for backup destinations.

The application deployment remains in Coolify. Terraform does not create application databases, OmniRoute secrets, Coolify `APP_KEY`, R2 access keys, or private SSH keys.

## Operator workflow

1. Install Terraform >= 1.6 and the pinned providers.
2. Use `ovhcloud vps list --output json` to identify the intended service and record its service name and IP in a local ignored `terraform.tfvars`; the `ovh_vps.existing` data source verifies that service without attempting to recreate it.
3. Obtain the approved Cloudflare domain/account ID and least-privilege API token from the external secret manager.
4. Copy `terraform.tfvars.example` to `terraform.tfvars` and replace every placeholder.
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
