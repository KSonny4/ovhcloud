# 03. Install and configure Coolify

This runbook uses **self-hosted Coolify on the same OVH VPS that initially runs the applications**. The dashboard and application hostnames are derived from the approved canonical domain in `docs/deployment-plan.md`; the example values below are not deployable defaults.

Coolify currently recommends a fresh server, at least 2 CPU cores, 2 GB RAM and free disk space. Builds and deployed workloads consume additional resources.

## 1. Final preflight

As root:

```bash
cat /etc/os-release
nproc
free -h
df -hT
ssh localhost true || true
```

Expected OS: Ubuntu 24.04 LTS.

Do not use Docker installed via Snap.

## 2. Temporary firewall requirements

For a self-hosted Coolify server, current Coolify documentation lists:

- 22/tcp: SSH
- 80/tcp: HTTP / certificate flow
- 443/tcp: HTTPS
- 8000/tcp: direct dashboard during bootstrap
- 6001/tcp: realtime dashboard when using direct-IP access
- 6002/tcp: web terminal when using direct-IP access

The final public surface should normally be 80/443 only. 8000/6001/6002 are bootstrap/direct-IP ports and can be closed after the dashboard is served through a domain.

If possible, restrict 8000/6001/6002 to your current source IP during bootstrap rather than the whole Internet.

## 3. Install with the official installer

Run as root:

```bash
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
```

The installer sets up the required Coolify directories, Docker components, OpenSSH integration and the localhost server connection.

When it finishes, verify containers:

```bash
docker ps
```

And inspect listeners:

```bash
ss -lntup
```

## 4. Claim the administrator immediately

Open:

```text
http://<VPS_IPV4>:8000
```

Create the administrator immediately. Coolify explicitly warns that whoever reaches the registration page first can become the instance administrator and gain root-equivalent server control.

Alternative: Coolify supports pre-creating the root user via installer environment variables. If using that route, never paste the chosen password into shell history or this repository.

## 5. Verify the localhost server

In Coolify:

`Servers -> localhost -> General`

Confirm it reports the server as reachable and validated.

Coolify manages even `localhost` via SSH. If validation fails, verify:

```bash
systemctl status ssh --no-pager
sshd -T | grep -E 'pubkeyauthentication|permitrootlogin|passwordauthentication'
ls -la /data/coolify/ssh/keys/
ls -la /root/.ssh/
```

Expected SSH policy includes:

```text
PubkeyAuthentication yes
PermitRootLogin prohibit-password
PasswordAuthentication no
```

Do not disable root key-based SSH if this is the account Coolify uses to manage localhost.

## 6. Back up the installation secrets immediately

This file is critical:

```text
/data/coolify/source/.env
```

In particular, `APP_KEY` is needed to decrypt values stored by Coolify during recovery.

View it only in a secure terminal:

```bash
sudo ls -l /data/coolify/source/.env
```

Store the `APP_KEY` and/or an encrypted copy of the file in your external password/secrets system. **Never commit it to Git.**

A later Coolify database backup without the original `APP_KEY` is not a complete recovery strategy.

## 7. Give Coolify a real dashboard domain

Recommended pattern:

```text
coolify.<your-domain>
```

Create an `A` record pointing that hostname to the VPS IPv4. Initially use DNS-only mode if that makes certificate troubleshooting simpler. Cloudflare proxying can be enabled after origin HTTPS works.

In Coolify configure the instance URL as:

```text
https://coolify.<your-domain>
```

Coolify's integrated proxy handles HTTPS when the domain resolves correctly and ports 80/443 reach the VPS.

Verify:

```bash
curl -I https://coolify.<your-domain>
```

Then log in through the HTTPS hostname.

## 8. Close direct dashboard ports

Once the domain works and the dashboard/web terminal work through 443, remove public access to:

- 8000/tcp
- 6001/tcp
- 6002/tcp

Coolify's documentation states these direct-IP ports are no longer required publicly when the dashboard is served through a domain using the Coolify proxy.

Keep 80/443 public.

SSH should normally be reached through the Cloudflare Tunnel + Access administration path rather than unrestricted public 22. Keep the OVH KVM/rescue path available as the emergency fallback.

## 9. Configure a wildcard application domain

This is optional but useful if the VPS will host many experiments/apps.

Example DNS:

```text
A  *.apps.example.com  -> <VPS_IPV4>
```

Then in Coolify:

`Servers -> localhost -> General -> Wildcard Domain`

Set:

```text
https://apps.example.com
```

Coolify can then generate hostnames such as:

```text
https://<application-id>.apps.example.com
```

Use explicit custom domains for production-facing applications where names matter.

## 10. First deployment smoke test

Use Coolify's simplest test before connecting a real repository:

1. Create a project, e.g. `platform-smoke-test`.
2. Add an application from Docker Image.
3. Image: `nginx:alpine`.
4. Container port: `80`.
5. Deploy.
6. Open the generated domain.

If this works, the Docker engine, proxy, routing and basic TLS path are functioning.

Delete the smoke-test app afterwards if you do not need it.

## 11. GitHub integration

For applications hosted on GitHub, add GitHub integration from Coolify rather than creating a general-purpose server deploy key manually for every project.

Principles:

- grant the smallest repository access practical;
- keep application deployment secrets in Coolify/environment configuration, not Git;
- never copy your personal GitHub SSH private key onto the VPS;
- prefer repository/app scoped credentials.

## 12. Resource limits

On a small VPS, one bad build or container can starve Coolify itself.

For important workloads, set sensible CPU/memory limits in Coolify/Docker where possible.

Regularly check:

```bash
free -h
df -hT
docker stats --no-stream
docker system df
```

If builds regularly push a VPS-1-sized host into swap/OOM, upgrade the VPS rather than tuning around chronic resource pressure.

## 13. Updates

Coolify self-hosted supports automatic updates, and auto-update is enabled by default in current documentation. For anything you care about, prefer controlled updates:

1. disable automatic installation of Coolify updates;
2. keep update checks enabled;
3. read release notes;
4. take an instance backup;
5. confirm no active deployment;
6. update manually from the dashboard;
7. verify apps and backups afterwards.

This avoids waking up to an unexpected control-plane change.

## Done when

- [ ] Coolify containers are running
- [ ] localhost server is reachable/validated
- [ ] administrator account is created
- [ ] `APP_KEY` is stored outside the VPS
- [ ] dashboard works over `https://coolify.<domain>`
- [ ] 8000/6001/6002 are no longer public
- [ ] 80/443 are reachable
- [ ] first nginx smoke deployment works
- [ ] automatic Coolify updates are configured deliberately

Next: [04. Configure Cloudflare](04-cloudflare.md)

## References

- Install: https://coolify.io/docs/start-with-self-hosted
- OpenSSH: https://coolify.io/docs/core/infrastructure/servers/openssh
- Firewall: https://coolify.io/docs/core/infrastructure/servers/firewall
- DNS: https://coolify.io/docs/core/networking/dns
- Domains: https://coolify.io/docs/core/networking/domains
- Updates: https://coolify.io/docs/core/instance-management/update
