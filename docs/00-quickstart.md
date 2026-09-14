# 00. From zero to a working Coolify VPS (canonical, noninteractive)

This is the canonical first-day path. It provisions a fresh VPS end to end
with a single command — no reinstall walkthroughs, no KVM sessions, no browser
logins, no dashboard clicking. Every step below is scripted, idempotent, and
fail-closed; credentials come only from OpenBao (plus OVH account
authorization), and every derived secret is escrowed back to OpenBao.

> The previous 26-step manual runbook now lives at
> [00-quickstart-legacy-manual.md](00-quickstart-legacy-manual.md). It is
> **not** the canonical path: use it only for break-glass emergencies (total
> lockout via OVH KVM/rescue) when automation is unreachable.

## Prerequisites (operator machine)

- `bao` authenticated against `https://secrets.pkubelka.cz` (runner identity).
- `ovhcloud` CLI with API credentials (`~/.ovh.conf`) for VPS discovery.
- An SSH client. No pre-existing keypair is required (the runner generates +
  escrows one when absent); no Terraform values need hand-editing.

## Step 1 — Order the VPS

Order (or select) an Ubuntu 24.04/26.04 VPS in the OVH manager. The runner
registers its SSH public key at your OVH account automatically, so installs
pick it up — note only the resulting hostname/IP and the Cloudflare zone.

## Step 2 — Run the provisioner (one command)

```bash
BAO_ADDR=https://secrets.pkubelka.cz \
PROVISION_HOST=<fresh-host-or-ip> PROVISION_ZONE=<zone> \
bash scripts/run-remote-provision.sh
```

This executes, in order, with per-stage verification: Ubuntu bootstrap
(swap, hardening, Docker engine + hello-world proof), Coolify pinned release
(first admin, dashboard FQDN, bootstrap-port closure, origin smoke check),
cloudflared + Tunnel/Access wiring (including fresh-edge DNS/ingress binding),
and the nightly R2 backup schedule (instance database + application workloads,
14-day retention, memory-only OpenBao pull — no credential file).

First access is deterministic (OVH account keys apply at install time only,
never retroactively): pick one before provisioning —
1. order/install the VPS with an existing key and pass `PROVISION_SSH_KEY`; or
2. mint one first (`bash scripts/run-remote-provision.sh --generate-key-only`
   prints the escrowed public key) and inject it at order time; or
3. for an already-ordered EMPTY host, reinstall with the key injected:
   `PROVISION_OVH_SERVICE=<service> bash scripts/run-remote-provision.sh`
   `--reinstall-with-key --i-confirm-host-is-fresh` (DESTRUCTIVE, refuses the
   preserved service). Without a working key the runner fails closed with
   this guidance instead of proceeding hopefully.
First use without `ROOT_USER_PASSWORD` generates and escrows it.

Dry-run first if you like: append `--dry-run` (no network touched), or limit
with `--stages bootstrap,coolify,edge,backup`.

## Step 3 — Verify (no login required)

```bash
bash scripts/validate-repository.sh
bash scripts/rehearse-fresh-environment.sh
```

Machine verification (service token, HTTP 200 expected):

```bash
# client id/secret from OpenBao secret/projects/ovhcloud/COOLIFY_ACCESS_SERVICE_TOKEN
curl -H "CF-Access-Client-Id: <id>" -H "CF-Access-Client-Secret: <secret>" \
  https://coolify.<zone>/login -o /dev/null -w '%{http_code}\n'
```

Human dashboard access stays `ksonny4@gmail.com` via Cloudflare Access OTP.

## Step 4 — Terraform state (already reconciled for the preserved VPS)

The preserved VPS, Tunnel, DNS, Access, and R2 bucket are imported into
R2-backed encrypted Terraform state. For any new plan/apply, load
authorization noninteractively (never write a tfvars file):

```bash
eval "$(BAO_ADDR=https://secrets.pkubelka.cz bash scripts/tf-env-from-openbao.sh)"
terraform -chdir=infra/terraform init -backend-config=backend.hcl
terraform -chdir=infra/terraform plan
```

A human must authorize any `terraform apply`.

## Step 5 — Backups and rollback

- Nightly: Coolify instance database + application databases/volumes -> R2
  (14-day retention), timer `coolify-backup.timer` on the host.
- Restore proof (disposable probe, production untouched):
  `bash scripts/rollback-coolify-backup.sh` on the host as root.
- Rotation procedures for every credential: [secret-rotation.md](secret-rotation.md).

## Continue reading

- [Runbook detail: deployment plan](deployment-plan.md) (evidence register)
- [Interfaces: runner/OpenBao/Terraform contracts](iac-interfaces.md)
- [Backup and restore details](05-backup-recovery.md)
- [Operations and upgrades](06-operations.md)
