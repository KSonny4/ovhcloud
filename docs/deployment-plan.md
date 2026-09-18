# Deployment plan

**Status:** Nomad-only migration (2026-09-18). The canonical domain is resolved (`pkubelka.cz`, UI `nomad.pkubelka.cz`); the next authorized apply converges the edge (UI DNS/Access, tunnel config, bucket migration) and `terraform plan` must show only the intended destroy/create pairs. Retired-plane evidence is archived in `evidence-archive/`. Fresh-host automation is implemented (stand-in evidence per operator decision, no paid second VPS); see `docs/08-iac-redesign-evidence.md`.

This plan is the machine-readable handoff for the runbooks in this repository. It records what was found, what changed, and what an authorized operator must still decide. It intentionally does not contain provider tokens, private keys, IP addresses, or production secret values.

## Evidence and change register

| Requirement / source | Finding | Implemented change | Status / remaining gate |
| --- | --- | --- | --- |
| `README.md:19-37`, `docs/00-quickstart.md:7-12` | OVH VPS origin with Ubuntu, Docker and Nomad; Cloudflare DNS/edge, Tunnel/Access and R2 | Terraform models the OVH VPS and Cloudflare resources; runbooks remain the host/application procedure | Live: reconciled, plan converges with no changes |
| `README.md`, `docs/02-host-bootstrap.md` | Steady state is tunnel-only (no public web ports), key-only SSH and Cloudflare Tunnel + Access administration | Terraform models the admin tunnel and access policy; host hardening remains an explicit post-bootstrap gate | DONE 2026-09-14: UFW denies 80/443, dashboard 200 via Tunnel, no public listeners |
| `docs/04-cloudflare.md:13-64`, `docs/07-omniroute.md:95-116` | Cloudflare is the public edge; API clients must not be forced through interactive Access | DNS, tunnel, private R2 and admin Access are represented in IaC; application API authentication stays in OmniRoute | Ready; API auth is application-owned |
| `docs/05-backup-recovery.md`, `docs/07-omniroute.md:134-189` | Recovery depends on R2, Nomad bootstrap material, application keys and tested restores | Secret inventory, encrypted-state requirement, backup/restore gates and rollback are now explicit | Workload proofs DONE 2026-09-14 (`RESTORE_OK`, byte-identical, `CONNECT_OK`); Nomad snapshot drill is the M5 gate; see `docs/08-iac-redesign-evidence.md` |
| `docs/03-nomad.md` vs README and docs 02/04 | Control-plane references must agree on Nomad-only | The retired-plane doc was replaced with the Nomad runbook | Resolved 2026-09-18 |
| Issue/ADR/TODO sources | No issue export, ADR, TODO/FIXME or machine-readable requirements source exists | This evidence table is the tracked audit source until an issue tracker export is provided | No additional issue IDs can be verified |
| Domain discovery | Repository only contains `example.com`, `<your-domain>` and `<VPS_IPV4>` placeholders; OVH CLI account has no domain-zone/domain-name result | Domain is a required Terraform input and never invented | **RESOLVED:** `pkubelka.cz`; UI `nomad.pkubelka.cz`, SSH `ssh.pkubelka.cz`; wildcard remains opt-in via `manage_application_wildcard=false` |
| OVH account discovery | `ovhcloud vps list --output json` found `vps-1525c977.vps.ovh.net`, running, 4 vCPU/8 GiB/75 GB, zone `os-uk2` | Terraform supports create/import; provider authorization is env-only via `scripts/tf-env-from-openbao.sh` (no tfvars file exists) and the existing service is imported | Validated 2026-09-13 (read-only): `running`, `vps-2027-model2`, 4 vCores/8192 MiB/75 GB SSD, `os-uk2` London UK2, IPv4 `57.129.155.203`, IPv6 `2001:41d0:801:2000::3663`; no mutation performed |
| Context workflow | Graft wiring graph is fresh but its index has no source nodes; generated cache is local | `CONTEXT.md`, this plan, and `docs/context-and-graft.md` define the context contract and freshness gate | `graft build` and `graft check` are required verification |

## Target architecture

```text
Cloudflare DNS + proxy/TLS (exclusive public edge)
  ├── nomad.pkubelka.cz -> Tunnel nomad-admin -> localhost:4646 (Terraform CNAME)
  ├── ssh.pkubelka.cz     -> Tunnel nomad-admin -> localhost:22 (Terraform CNAME)
  ├── omni.pkubelka.cz    -> Tunnel nomad-admin -> localhost:80 (Terraform CNAME; production cutover 2026-09-14, no Access app; Pi tunnel stays as fallback)
  ├── omniroute.pkubelka.cz -> Tunnel nomad-admin -> localhost:80 (Terraform CNAME; staging, no Access app)
  ├── registry.pkubelka.cz -> Tunnel nomad-admin -> localhost:80 (Terraform CNAME; plan-only, no Access app; see docs/09-docker-registry.md)
  ├── Access: human OTP/email policy (ksonny4@gmail.com) + machine service token
  └── private R2 bucket   <- Nomad snapshot/database/volume backups (Terraform + probe)

OVH VPS vps-1525c977.vps.ovh.net (Ubuntu 26.04 live; fresh bootstrap supports 24.04/26.04)
  ├── public web ports: none (UFW deny 80/443; all traffic via Cloudflare Tunnel)
  ├── administration: outbound cloudflared + Access
  └── OmniRoute: one replica, private Redis, persistent /app/data, internal :20128
```

Cloudflare is the exclusive public DNS/edge provider. OVH remains the compute/origin provider and emergency KVM/rescue path. No other DNS, CDN, tunnel, or public-edge provider is part of this plan.

## IaC layout and apply boundaries

`infra/terraform/` contains one root configuration for the provider resources:

- `ovh_vps.platform`: optional VPS ordering contract. Existing infrastructure is verified read-only through `data.ovh_vps.existing` rather than implicitly recreated; Ubuntu image selection and SSH-key bootstrap remain explicit operator gates because the pinned provider schema does not expose those fields on this resource.
- Cloudflare DNS CNAMEs for the Nomad UI and SSH hostname point at the Tunnel (`<tunnel-id>.cfargotunnel.com`), not at origin A records; the OmniRoute application hostnames (`omni.` production, `omniroute.` staging) are likewise Tunnel CNAMEs with no Access app; the application wildcard is opt-in and disabled by default.
- Cloudflare Tunnel `nomad-admin` with declared ingress plus `prevent_destroy`; cloudflared install/verify is scripted in `scripts/configure-tunnel-access.sh`.
- Cloudflare Access: human OTP/email policy retained plus a scoped machine service token (`non_identity`) escrowed to OpenBao by `scripts/ensure-service-token.sh` (Terraform owns token identity + policy binding only; no vault provider/resources in the module, so the live plan converges with zero residual adds); no provisioning step depends on browser login.
- A private Cloudflare R2 bucket for backup destinations.
- Fresh-host automation (never targets the preserved VPS): `scripts/bootstrap-vps.sh` (Ubuntu packages, key-only SSH, swap, time), `scripts/provision-nomad.sh` (pinned release, ACL bootstrap, health checks), `scripts/configure-tunnel-access.sh` (cloudflared install, service-token verification), `scripts/backup-r2-probe.sh` (R2 write/restore probe). Disposable rehearsal: `scripts/rehearse-fresh-environment.sh` (idempotent twice, no plaintext secrets).
- No application secrets or tunnel tokens are generated into the repository. Terraform variables marked sensitive come ONLY from the existing OpenBao instance (`https://secrets.pkubelka.cz`) via `scripts/tf-env-from-openbao.sh` (env-only `TF_VAR_*`, never files). No external secret manager, CLI profile, or credential file participates in provider authorization.

The default configuration is non-live: `provision_ovh_vps = false` and there is no apply workflow. A human may run a reviewed plan/apply only after:

1. confirming the approved domain and Cloudflare zone;
2. configuring an encrypted remote Terraform state backend with locking;
3. loading provider authorization EXCLUSIVELY from OpenBao: two-step eval of `scripts/tf-env-from-openbao.sh` (`loader_out="$(...)" || exit 2`, then `eval "$loader_out"`) for `TF_VAR_*` + `OVH_*` env; the OVH CLI runs only via the explicit HOME-redirected channel (`ovh_cli`), the Cloudflare provider only via explicit `api_token = var...` args — ambient profiles, operator dotfiles, and credential files are never read (rehearsal gates fail any script that references them);
4. supplying the existing OVH service name and using the read-only `data.ovh_vps.existing` check if it is the intended host;
5. reviewing the plan for replacement, reinstall, DNS, tunnel, Access and R2 changes;
6. verifying KVM/rescue access and current R2/OVH backups;
7. explicitly authorizing the apply.

The repository's automated validation workflow must never run `terraform apply`, `ovhcloud reinstall`, `ovhcloud reboot`, `ovhcloud stop`, `ovhcloud terminate`, or equivalent mutating commands (this binds automation only; a human operator explicitly authorizes any live apply).

## Domain contract

The canonical domain is resolved: `pkubelka.cz`. UI `nomad.pkubelka.cz`, SSH `ssh.pkubelka.cz`. The optional application wildcard remains operator-approved and disabled by default (`manage_application_wildcard = false`).

- `nomad.<approved-domain>` — Nomad UI
- `ssh.<approved-domain>` — SSH Tunnel/Access hostname
- `*.<approved-domain>` — optional application wildcard
- `omni.<approved-domain>` — OmniRoute production API hostname (Nomad via Tunnel, no Access app; cut over 2026-09-14, Pi tunnel as fallback)
- `omniroute.<approved-domain>` — OmniRoute staging API hostname (Nomad via Tunnel, no Access app)
- `registry.<approved-domain>` — private Docker registry (Nomad `registry:2` via Tunnel, no Access app; plan-only, see `docs/09-docker-registry.md`)

The authorized operator must provide a Cloudflare-managed zone and decide whether the wildcard and OmniRoute hostname are enabled. The plan is reviewed with values supplied via the two-step loader form (`loader_out="$(...)" || exit 2`, then `eval "$loader_out"`; env-only, no tfvars file is ever written).

## Secret and state lifecycle

| Secret / sensitive value | Owner | Storage | Rotation / recovery gate |
| --- | --- | --- | --- |
| Cloudflare API token/account ID | platform operator | OpenBao `secret/projects/nomad/ADMIN_CLOUDFLARE` via `tf-env-from-openbao.sh` (`TF_VAR_cloudflare_api_token`, memory-only) | least-privilege token; revoke and replace after suspected exposure |
| OVH application credentials | platform operator | OpenBao `secret/projects/nomad/OVH_API` (`application_key`, `application_secret`, `consumer_key`, `endpoint`) via `OVH_*` env into `ovh_cli` (explicit HOME-redirected config; ambient `~/.ovh.conf` never read) | revoke API keys; never export into Git |
| Cloudflare Tunnel secret | platform operator | OpenBao per-target `secret/projects/nomad/EDGE_TUNNEL_<NAME>` (`tunnel_secret`) via `ensure-tunnel.sh` (create + escrow, never the preserved `nomad-admin` singleton) | rotate tunnel and Access policy after exposure |
| R2 access key/secret | backup owner | host-timer memory-only pull from OpenBao (no credential file, no control-plane destination) | scoped to private backup bucket; test a restore after rotation |
| Nomad bootstrap material | Nomad owner | OpenBao `secret/projects/nomad/NOMAD_BOOTSTRAP` (`acl_token`, `acl_accessor`, `gossip_key`): provisioner ACL-bootstraps over SSH + escrows (memory-only, fail closed) | restore test must re-administer from escrow |
| OmniRoute `STORAGE_ENCRYPTION_KEY`, `API_KEY_SECRET`, `JWT_SECRET` | automation-derived | OpenBao `secret/projects/nomad/OMNIROUTE` via `ensure-omniroute-secrets.sh` (generate-if-absent + escrow, reuse otherwise; values never printed/disk); restore re-injects from escrow via `fetch-app-secrets.sh` blob (no human relay) | restore test must load known configuration |
| Cloudflare machine service token | Terraform-generated, escrowed in OpenBao | `secret/projects/nomad/EDGE_ACCESS_SERVICE_TOKEN` (`client_id`, `client_secret`) | noninteractive verification must pass without browser login |
| Docker registry htpasswd + `REGISTRY_HTTP_SECRET` | registry owner | OpenBao `secret/projects/nomad/REGISTRY` (`htpasswd`, `http_secret`): generated off-host, relayed into the Nomad job file mount/env memory-only, never committed | rotate htpasswd + redeploy; verify with authenticated `docker login` |
| Terraform state | platform owner | encrypted remote backend with locking (`backend.hcl`, ignored; `backend.hcl.example` committed) | never use an unencrypted local state for production apply; rehearsal uses disposable local state only |

## Deployment and rollback sequence

1. Run `ovhcloud vps list --output json` and record the service, state, model, zone and IP through the operator's secure notes; do not commit the output.
2. Confirm the approved Cloudflare domain and provider credentials.
3. Run `terraform fmt -check`, `terraform init -backend=false`, `terraform validate`, and the repository validation script.
4. Configure the encrypted remote backend and import the existing VPS if applicable.
5. Run a reviewed `terraform plan`; verify no replacement/reinstall is proposed accidentally.
6. Apply Cloudflare DNS, Tunnel/Access and private R2 resources only after authorization.
7. Follow the bootstrap runbook: Ubuntu hardening, Cloudflare Tunnel health, UI HTTPS, closure of bootstrap ports, Nomad canary job deployment, backups and restore proof.
8. For risky changes, verify recent R2/DB backups and an OVH recovery path first. Roll back by restoring the prior Terraform state/configuration and DNS records, or by using the tested snapshot/volume restore procedure; use an OVH snapshot only as a temporary pre-change rollback point.
9. After any apply or recovery, run `bash scripts/healthcheck.sh`, verify the admin Tunnel + UI 200 + absence of public web listeners, and record the evidence in the issue/status table.

## Verification commands

From the repository root:

```bash
bash scripts/validate-repository.sh
bash scripts/rehearse-fresh-environment.sh
terraform -chdir=infra/terraform fmt -check -recursive
terraform -chdir=infra/terraform init -backend=false -input=false
terraform -chdir=infra/terraform validate
graft check
git diff --check
```

Provider-aware operators additionally run, from `infra/terraform/`:

```bash
terraform fmt -check -recursive
terraform init -backend=false -input=false
terraform validate
loader_out="$(BAO_ADDR=https://secrets.pkubelka.cz bash scripts/tf-env-from-openbao.sh)" || exit 2  # never bare eval: masks loader failure

eval "$loader_out"
terraform plan -input=false
```

The final command is a plan only (live-backend convergence is proven with
`-backend-config=backend.hcl`). Provider credentials arrive exclusively via
the OpenBao-backed env loader; no `-var-file` is used anywhere.
