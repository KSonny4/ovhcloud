# Noninteractive IaC interfaces

This document defines the small interfaces between provider authorization, Terraform, guest bootstrap, Coolify, Cloudflare Access, and OpenBao. The implementations may change; callers should depend on these contracts rather than on ad-hoc shell variables or browser state.

## Operator input interface

The deployment runner receives only provider authorization and a target declaration. Values are read from OpenBao at `https://secrets.pkubelka.cz` and injected into the process environment or an ephemeral file descriptor. They are never written to `terraform.tfvars`, shell history, CI logs, or repository files.

### Remote provisioning runner (`scripts/run-remote-provision.sh`)

The runner is the noninteractive project channel that provisions a fresh host
remotely; no stage requires manually running local root scripts on the target.
One invocation executes bootstrap -> Coolify -> Tunnel/Access -> R2 backup
schedule over SSH with per-stage verification, failing closed at the first
failure:

- Inputs: `PROVISION_HOST`, `PROVISION_ZONE` (Cloudflare zone),
  `PROVISION_SSH_USER` (default `ubuntu`), `PROVISION_SSH_KEY`, plus
  `ROOT_USERNAME/ROOT_USER_EMAIL/ROOT_USER_PASSWORD` for first-admin
  bootstrap and `R2_ENDPOINT` (defaults to the account endpoint).
  The dashboard hostname is always `coolify.${PROVISION_ZONE}` (single
  domain contract with Terraform; a `PROVISION_DASHBOARD_HOST` override
  no longer exists and is refused fail-closed). It is used consistently
  for Coolify FQDN, Tunnel ingress/DNS, and every HTTP verification.
- Refuses the preserved VPS via the shared service-identity guard
  (`scripts/lib/preserved-guard.sh`): resolves the target to all its A/AAAA
  addresses and intersects with the OVH service identity (live IP set from
  the OVH API, embedded fallback, reverse-DNS match) before any network or
  secret access. On-target stages additionally refuse when the machine
  itself is the preserved VPS.
- Retrieves from OpenBao by name only: `COOLIFY_SSH_PUBLIC_KEY.value`,
  per-target tunnel entry `COOLIFY_TUNNEL_<NAME>.{tunnel_id,tunnel_token}`
  (derived from `TUNNEL_NAME`; `coolify-admin` is refused). Tunnel-entry
  roles are disjoint by design: `COOLIFY_TUNNEL_SECRET.tunnel_secret`
  feeds ONLY the preserved Terraform tunnel config via the loader;
  `COOLIFY_TUNNEL_TOKEN.tunnel_token` is the preserved connector's cold
  recovery escrow (break-glass only, read by no automation — the live
  connector owns its `--token-file` and rotation goes through the API);
  per-target entries serve fresh connectors only,
  `COOLIFY_ACCESS_SERVICE_TOKEN.{client_id,client_secret,token_id}`,
  `OVH_API.{application_key,application_secret,consumer_key,endpoint}`
  (R2 keys are deliberately NEVER retrieved operator-side: the target pulls
  them memory-only via `fetch-r2-env.sh`); exits when any required field
  is absent.
- Copies the stage scripts (bootstrap, provision, tunnel/access, schedule +
  workload companion + fetch wrapper + both rollback scripts) plus the guard
  library to `/tmp/ovh-provision` on the target — scripts only, no credential
  files. Stage secrets travel as a base64 env blob on each SSH command's
  stdin (never argv, never disk); R2 keys are absent from the blob by
  construction. Runs each stage with `sudo -E`, verifies (docker
  hello-world, origin login, edge wiring + dashboard HTTP 200, timer
  enabled). An EXIT trap removes remote stage material on every exit path;
  a cleanup failure warns loudly.
- `--dry-run` logs the full plan without touching the network (exercised twice
  byte-identical by the rehearsal `runner_channel` phase); `--stages` selects
  a subset. Initial SSH key injection on a fresh OVH VPS (order/reinstall
  time) is the one explicit operator prerequisite.

### OVH provider adapter

The adapter supplies the standard OVH provider inputs:

- endpoint: `https://eu.api.ovh.com/1.0` (override only for the selected OVH region);
- application key;
- application secret;
- consumer key;
- target service name when reconciling an existing VPS.

The adapter must support read-only discovery and plan-time verification separately from an explicitly authorized provisioning operation. A current VPS has lifecycle protection and must not be replaced by a plan refresh.

### Cloudflare provider adapter

The adapter supplies one scoped Cloudflare API token, the account ID, and the approved zone. The token scope must cover only the declared zone DNS operations and the selected account's Tunnel, Access application/policy/service-token, identity-provider, and R2 operations. The adapter consumes the `ADMIN_CLOUDFLARE` OpenBao entry (a scoped Cloudflare API token with Zone-DNS + Account Tunnel/Access/R2 + IdP grants). Historical note: an earlier `CF_DEPLOY_TOKEN` field existed during rotation and was superseded the same day; no script reads it (the runner, wire, and loader all use `ADMIN_CLOUDFLARE`). Field values are never copied or printed.

### OpenBao adapter

The runner uses the existing remote OpenBao endpoint and a pre-authorized runner identity. Secret reads return values only to child processes that need them; secret writes accept generated values through stdin or provider state and return metadata only. The repository records secret paths and field names, never values.

## Terraform state interface

Production state is an encrypted, locked remote backend. Local state is allowed only for disposable rehearsal. The backend must protect sensitive provider and generated-secret values and must support import of the current Cloudflare resources before any apply.

The Terraform root exposes these logical inputs:

- target domain and Cloudflare zone/account;
- existing OVH service name and origin identity;
- fresh-VPS plan/image parameters, disabled by default for the preserved host;
- admin identity set, containing `ksonny4@gmail.com`;
- backup bucket name, region, retention, and restore-test mode;
- bootstrap artifact version and supported Ubuntu image;
- OpenBao mount/path names, not secret values.

## Managed resource interface

The declared modules have these responsibilities:

1. **origin** — read/import the existing OVH VPS and optionally order a fresh one behind an explicit opt-in; lifecycle protection prevents replacement of the current service;
2. **edge** — manage Cloudflare DNS, proxied TLS/edge routing, Tunnel, and hostname ingress;
3. **access** — manage a human dashboard policy for `ksonny4@gmail.com`, a narrowly scoped machine service token, and the identity-provider configuration needed by optional human use;
4. **guest bootstrap** — install and configure Ubuntu packages, Docker, swap, cloudflared, SSH trust, and health probes through an automated provider-supported channel;
5. **coolify** — install a pinned Coolify release, set its domain and generated application key, create the first administrator through a supported noninteractive mechanism, and expose health state;
6. **backup** — create a private R2 bucket, scoped credentials, backup schedule, retention, restore probe, and rollback artifacts.

No module owns unrelated existing Cloudflare tunnels, DNS records, Access applications, or account settings.

## Generated secret interface

Generated values are written to OpenBao under stable paths and are referenced by name elsewhere:

| Logical value | OpenBao path/fields | Consumers |
| --- | --- | --- |
| Coolify SSH key | `secret/projects/ovhcloud/COOLIFY_SSH_PRIVATE_KEY` / `COOLIFY_SSH_PUBLIC_KEY` | guest bootstrap, Coolify machine connection |
| Tunnel config secret (preserved tunnel) | `secret/projects/ovhcloud/COOLIFY_TUNNEL_SECRET` / `tunnel_secret` | Terraform loader → `TF_VAR_cloudflare_tunnel_secret` → preserved tunnel config (only consumer) |
| Tunnel connector token (preserved, cold recovery) | `secret/projects/ovhcloud/COOLIFY_TUNNEL_TOKEN` / `tunnel_token` | break-glass connector reinstall ONLY; read by no automation (live connector owns its `--token-file`; rotation via API) |
| Tunnel connector credential (per fresh target) | `secret/projects/ovhcloud/COOLIFY_TUNNEL_<NAME>` / `tunnel_id`, `tunnel_token` | `ensure-tunnel.sh` creates + escrows; runner consumes; cloudflared service installation |
| Cloudflare machine Access credential | `secret/projects/ovhcloud/COOLIFY_ACCESS_SERVICE_TOKEN` / `client_id`, `client_secret` | noninteractive verification and automation |
| Coolify application key/admin bootstrap | `secret/projects/ovhcloud/COOLIFY_ADMIN` / `app_key`, `email`, `password` | Coolify bootstrap and recovery |
| R2 backup credential | `secret/projects/ovhcloud/COOLIFY_R2` / `access_key_id`, `secret_access_key`, `bucket`, `endpoint` (four fields; every consumer fails closed on any missing field) | host-timer backup plane + restore probe (the Coolify in-app S3 destination was deleted; no credentials in Coolify) |

Values must be sensitive in Terraform schemas and redacted from command output. If the selected provider cannot safely write a generated value to OpenBao, the apply must fail rather than silently leave it in an untracked local file.

## Verification interface

Every automated phase returns structured, redacted status:

- `provider_access`: authorization works and required scopes are present;
- `origin_identity`: expected OVH service is running and protected from replacement;
- `guest_ready`: supported Ubuntu, Docker, swap, SSH trust, cloudflared, and health checks pass;
- `edge_ready`: DNS, Tunnel ingress, Access policy, TLS, and service-token request pass;
- `coolify_ready`: release, domain, admin bootstrap, containers, and health endpoint pass;
- `backup_ready`: R2 bucket, backup object, restore probe, retention, and rollback metadata pass;
- `rehearsal_ready`: a disposable/fresh target completes idempotently twice and leaves no plaintext secret artifact.

A human may use the dashboard after deployment, but no provisioning or machine verification step may depend on that browser session.
