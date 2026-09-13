# 04. Configure Cloudflare

Cloudflare has three roles in this setup:

1. DNS / reverse proxy in front of public web applications.
2. Tunnel + Access for human administration, especially SSH.
3. R2 as off-machine S3-compatible backup storage.

The VPS itself remains at OVHcloud.

## 1. DNS layout

A simple layout for one domain is:

```text
coolify.example.com   -> Coolify dashboard
ssh.example.com       -> Cloudflare Tunnel -> localhost:22
*.example.com         -> generated/experimental application subdomains
example.com           -> optional application/root site
```

For normal Coolify web traffic, create:

```text
Type  Name      Value
A     coolify   <VPS_IPV4>
A     *         <VPS_IPV4>
```

Add an apex record only if you actually want the root domain on this VPS:

```text
A     @         <VPS_IPV4>
```

The SSH hostname is created as a Cloudflare Tunnel route and should not point directly to the VPS IP.

Do not create an `AAAA` record until you have deliberately tested IPv6 end to end. A broken IPv6 path can cause domain/certificate problems even when IPv4 is healthy.

## 2. Public web proxying

During the first Coolify/domain setup, using Cloudflare **DNS only** is the easiest path to debug:

```text
client -> DNS -> OVH VPS -> Coolify proxy
```

Once origin HTTPS works, turn Cloudflare proxying on:

```text
client -> Cloudflare -> OVH VPS -> Coolify proxy
```

Use:

```text
SSL/TLS mode: Full (strict)
```

Do not use Flexible SSL.

For important public web applications, proxying through Cloudflare gives you Cloudflare's edge protections while Coolify continues to route the application on the origin.

## 3. Create the administrative Cloudflare Tunnel

In Cloudflare:

1. go to `Networking -> Tunnels`;
2. create a tunnel for the OVH VPS;
3. select the Linux connector;
4. run the generated `cloudflared` installation command on the VPS;
5. verify the connector becomes **Healthy**.

Cloudflare Tunnel establishes outbound-only connections from `cloudflared` to Cloudflare. The administrative tunnel therefore does not require opening a new inbound port on the VPS.

On the VPS:

```bash
systemctl status cloudflared --no-pager
journalctl -u cloudflared -n 50 --no-pager
```

Treat the tunnel token as a secret. Do not commit it.

## 4. Publish SSH through the tunnel

Add a published application route:

```text
Hostname: ssh.example.com
Service:  SSH
Target:   localhost:22
```

Then create a Cloudflare Access self-hosted application for `ssh.example.com` and require your chosen identity/account.

Do not expose the SSH tunnel hostname without an Access policy.

On the workstation, install `cloudflared` and configure OpenSSH:

```bash
brew install cloudflared
command -v cloudflared
```

Example `~/.ssh/config`:

```sshconfig
Host ovh-cloudflare
    HostName ssh.example.com
    User root
    IdentityFile ~/.ssh/ovh_vps_ed25519
    ProxyCommand /opt/homebrew/bin/cloudflared access ssh --hostname %h
```

Replace the `cloudflared` path with the path returned by `command -v cloudflared` if needed.

Test:

```bash
ssh ovh-cloudflare
```

Cloudflare Access should authenticate you before the SSH session is established.

After this works and OVH KVM/rescue access is understood, remove unrestricted public TCP 22 at the provider firewall. Keep the local SSH daemon running because both Coolify and the tunnel still use it.

## 5. Coolify dashboard

After creating:

```text
A coolify <VPS_IPV4>
```

configure the Coolify instance URL as:

```text
https://coolify.example.com
```

Verify public DNS:

```bash
dig +short coolify.example.com A
```

Verify HTTPS:

```bash
curl -I https://coolify.example.com
```

Only after this works should direct public Coolify ports 8000/6001/6002 be closed.

For extra protection, put a Cloudflare Access policy in front of `coolify.example.com` as well. Keep the Access policy limited to the dashboard/admin hostname. Do not accidentally apply it to public application wildcard domains.

## 6. Wildcard application domains

For many small apps, a wildcard record avoids adding DNS manually for every experiment:

```text
A * <VPS_IPV4>
```

In Coolify:

`Servers -> localhost -> General -> Wildcard Domain`

set:

```text
https://example.com
```

Coolify can then generate application domains such as:

```text
https://<application-id>.example.com
```

The wildcard DNS record does **not** cover the apex `example.com`, so create a separate `@` record if the apex should resolve to this host.

For important public applications, explicit names such as `radar.example.com` are easier to understand than generated IDs even if the wildcard record already resolves them.

## 7. Why the baseline does not tunnel every web application

Cloudflare Tunnel can publish HTTP/HTTPS services and supports wildcard hostname ingress rules. A fully tunnelled architecture can therefore hide the origin and remove direct inbound 80/443 as well.

This runbook deliberately starts simpler:

```text
public apps: Cloudflare proxy -> public 80/443 -> Coolify proxy
administration: Cloudflare Access -> Tunnel -> localhost services
```

Reasons:

- Coolify's normal domain/TLS/proxy flow remains straightforward;
- wildcard application domains require less tunnel-specific configuration;
- recovery/debugging is simpler;
- the highest-value administrative surface, SSH, no longer needs a public inbound port.

Moving public applications behind Tunnel later is a valid hardening step, but do it deliberately and test wildcard routing, WebSockets, uploads, callbacks and certificate behaviour first.

## 8. Create the R2 backup bucket

In Cloudflare:

`R2 -> Create bucket`

Suggested bucket name:

```text
ovh-coolify-backups
```

The bucket should be private.

Do not enable public access for backups.

## 9. Create an R2 token

Create an R2 API token with **Object Read & Write** access, scoped only to the backup bucket if possible.

Cloudflare will show:

- Access Key ID
- Secret Access Key
- S3 endpoint

Copy them immediately into your password/secrets manager.

Never commit them here.

## 10. Add R2 to Coolify

In Coolify:

`S3 Storages -> Add`

Enter:

```text
Name:       cloudflare-r2-backups
Bucket:     ovh-coolify-backups
Endpoint:   <R2 S3 endpoint from Cloudflare>
Access key: <R2 Access Key ID>
Secret key: <R2 Secret Access Key>
Region:     leave/default according to Coolify's R2 guide
```

Select **Validate Connection & Continue**.

Coolify validates the storage by making an S3-compatible object-list request.

Do not continue to the backup section until validation succeeds.

## 11. R2 free-tier expectations

Cloudflare R2 Standard currently includes a monthly free tier. Treat it as a useful allowance rather than a backup-retention guarantee.

For a small OmniRoute deployment, daily compressed `/app/data` archives with roughly 30-copy retention are expected to be small enough to fit comfortably unless the application state grows substantially.

Do not rely on assumptions. Watch actual bucket size in Cloudflare and keep retention limits configured in Coolify.

The repository owner also has a separate pricing watch configured to flag future R2 free-tier/pricing changes.

## 12. Backup bucket separation

If this server starts hosting important data, prefer either:

- a dedicated bucket for this VPS; or
- a dedicated prefix/layout per server/app.

Do not reuse application object-storage credentials as backup credentials. Separate credentials reduce the blast radius of a compromised application.

## Done when

- [ ] `coolify.example.com` resolves to the VPS
- [ ] dashboard works over HTTPS
- [ ] wildcard DNS exists if wanted
- [ ] Cloudflare proxy mode is deliberate
- [ ] SSL mode is Full (strict) when proxied
- [ ] Cloudflare Tunnel connector is healthy
- [ ] `ssh.example.com` routes through the tunnel to `localhost:22`
- [ ] Cloudflare Access protects the SSH hostname
- [ ] SSH through Cloudflare works from the workstation
- [ ] unrestricted public TCP 22 has been removed/restricted
- [ ] private R2 backup bucket exists
- [ ] R2 token is scoped and stored outside Git
- [ ] Coolify validates R2 successfully

Next: [05. Backups and recovery](05-backup-recovery.md)

## References

- Coolify DNS: https://coolify.io/docs/core/networking/dns
- Coolify domains: https://coolify.io/docs/core/networking/domains
- Coolify R2: https://coolify.io/docs/core/s3-storage/r2
- Coolify Cloudflare protection: https://coolify.io/docs/integrations/security/cloudflare/ddos-protection
- Cloudflare Tunnel: https://developers.cloudflare.com/tunnel/
- Cloudflare Tunnel routing: https://developers.cloudflare.com/tunnel/concepts/routing/
- Cloudflare SSH through Access: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/ssh/ssh-cloudflared-authentication/
