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
