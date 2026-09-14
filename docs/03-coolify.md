# 03. Install and configure Coolify

The automated path is `scripts/provision-coolify.sh`, executed on the target
by the provisioner (`scripts/run-remote-provision.sh --stages coolify`, see
[00. Quickstart](00-quickstart.md)). It installs the pinned Coolify release
with the official installer, creates the first admin from OpenBao-backed
`ROOT_*` values, configures the FQDN, tightens the firewall, and runs a
domain smoke test. Onboarding is fully noninteractive: the provisioner
reconciles a default project + production environment in `coolify-db`
(idempotent SQL, existing projects untouched), gates on admin +
reachable localhost + project + environment, and the runner then executes
`scripts/verify-coolify-onboarding.sh` (read-only, fail closed) — the
coolify stage cannot finish while onboarding remains incomplete. No
dashboard click participates (the preserved instance's `context-fabric`
project predates this automation and is preserved as-is).

## 1. Automated path (primary)

What the Coolify stage does and verifies:

- Official installer at the pinned version (`COOLIFY_VERSION`, default
  4.3.19); Docker comes from the bootstrap stage, never Snap.
- First admin (`ksonny4@gmail.com`) via `ROOT_USERNAME/ROOT_USER_EMAIL/
  ROOT_USER_PASSWORD` from OpenBao (generated + escrowed when absent).
- Instance URL `https://coolify.<zone>`; direct dashboard ports
  (8000/6001/6002) closed after the domain serves; origin 80/443 denied
  (tunnel-only; 80/443 serve at the Cloudflare edge, never at origin).
- `localhost` server reachable and validated (Coolify manages it over SSH;
  root key login required — provided by the bootstrap stage).
- `APP_KEY` escrowed to OpenBao (`COOLIFY_ADMIN`); never in Git.
- Versioned releases only; automatic Coolify updates stay deliberately
  configured (backup first, update manually, verify after).

Routine use is the dashboard at `https://coolify.pkubelka.cz` (Cloudflare
Access OTP as `ksonny4@gmail.com`): create projects, deploy from images or
GitHub (smallest practical scope, secrets in Coolify environment config,
never personal keys on the VPS), set CPU/memory limits on small hosts.

## Dashboard realtime over the tunnel

The dashboard page dials `wss://<host>/app/<key>` (same-origin 443:
`getRealtime()` returns null for port-less URLs) and the web terminal
dials `wss://<host>/terminal/ws`. The tunnel bypasses Traefik — which owns
the matching `PathPrefix` routes for direct-origin access — so the tunnel
ingress fans out explicitly (`infra/terraform/main.tf`, path rules BEFORE
the bare-hostname rule; first match wins): `/app/*` → `localhost:6001`,
`/terminal/ws/*` → `localhost:6002`, rest → `localhost:8000`. If the
dashboard ever shows "Cannot connect to real-time service" again, check
in order: realtime container healthy → tunnel ingress path rules present
and ordered → edge WS upgrade returns 101 (never open public 6001/6002;
Cloudflare would not serve them anyway). `scripts/healthcheck.sh` covers
the origin-side WS handshake plus the proxy image.

## Proxy (Traefik) minor upgrades

Coolify tracks `traefik_outdated_info` and banners newer minor branches.
Supported path (used for v3.6 → v3.7 on 2026-09-14): review the Traefik
migration guide for the target branch (v3.7 notes touch only
k8s-providers/wildcard-host/TLS-options — none apply to our file +
docker provider usage), then via the API: `GET` the server proxy
configuration, change only the `traefik:` image tag, `PUT`
`/servers/{uuid}/proxy/configuration` (base64), `POST`
`/servers/{uuid}/proxy/restart`, and verify dashboard + apps + WS 101.
Rollback is the same path with the previous tag (proxy compose backups
live under `/data/coolify/proxy/backups/`). Never edit the proxy image
by hand on the host — Coolify reconciles it and the change would drift.

## Done when

- [x] Coolify containers running, `localhost` validated
- [x] admin exists, `APP_KEY` escrowed outside the VPS
- [x] dashboard serves `https://coolify.<zone>`, direct ports closed
- [x] onboarding complete (server + project)
- [x] updates configured deliberately

Next: edge and backups are provisioner stages; see [04](04-cloudflare.md)
and [05](05-backup-recovery.md).

## Appendix: break-glass (automation unavailable)

Official installer (root, pinned — never an unreviewed pipe):

```bash
curl -fsSL https://cdn.coollabs.io/coolify/install.sh -o /tmp/coolify-install.sh
# review /tmp/coolify-install.sh, then:
sudo bash /tmp/coolify-install.sh 4.3.19
```

Claim the admin immediately at `http://<VPS_IPV4>:8000` (whoever registers
first owns the instance), or pre-create via `ROOT_*` env without touching
shell history. Back up `/data/coolify/source/.env` (`APP_KEY`) externally
at once.

## References

- Install: https://coolify.io/docs/start-with-self-hosted
- OpenSSH: https://coolify.io/docs/core/infrastructure/servers/openssh
- Firewall: https://coolify.io/docs/core/infrastructure/servers/firewall
- Updates: https://coolify.io/docs/instance-management/update
