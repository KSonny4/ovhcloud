# 04. Configure Cloudflare

Cloudflare has two roles in this setup:

1. DNS / optional reverse proxy in front of web applications.
2. R2 as off-machine S3-compatible backup storage.

The VPS itself remains at OVHcloud.

## 1. DNS layout

A simple layout for one domain is:

```text
coolify.example.com   -> Coolify dashboard
*.example.com         -> generated/experimental application subdomains
example.com           -> optional application/root site
```

Create these records in Cloudflare DNS:

```text
Type  Name      Value
A     coolify   <VPS_IPV4>
A     *         <VPS_IPV4>
```

Add an apex record only if you actually want the root domain on this VPS:

```text
A     @         <VPS_IPV4>
```

Do not create an `AAAA` record until you have deliberately tested IPv6 end to end. Coolify warns that a broken IPv6 path can cause domains/certificate requests to fail even when IPv4 is healthy.

## 2. Start DNS-only, then optionally proxy

During the first Coolify/domain setup, using Cloudflare **DNS only** is the easiest path to debug:

```text
client -> DNS -> OVH VPS -> Coolify proxy
```

Once origin HTTPS works, you can turn Cloudflare proxying on:

```text
client -> Cloudflare -> OVH VPS -> Coolify proxy
```

If proxying through Cloudflare, use:

```text
SSL/TLS mode: Full (strict)
```

Do not use Flexible SSL.

Coolify's current Cloudflare integration guidance also recommends `Full (strict)` and optionally `Always Use HTTPS`.

## 3. Coolify dashboard record

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

## 4. Wildcard application domains

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

## 5. Cloudflare proxying policy

Reasonable baseline:

- public websites/APIs: proxy through Cloudflare if compatible;
- Coolify dashboard: can be proxied after origin HTTPS is proven;
- non-HTTP protocols: do not expect the normal Cloudflare HTTP proxy to carry arbitrary TCP/UDP traffic;
- databases: do not publish them just because DNS can point at them.

If every public HTTP hostname is proxied through Cloudflare, you can later consider restricting origin 80/443 to Cloudflare source ranges. Do that only after testing certificate renewal, health checks and every required direct path. It increases security but also makes recovery/debugging less forgiving.

## 6. Create the R2 backup bucket

In Cloudflare:

`R2 -> Create bucket`

Suggested bucket name:

```text
ovh-coolify-backups
```

The bucket should be private.

Do not enable public access for backups.

## 7. Create an R2 token

Create an R2 API token with **Object Read & Write** access, scoped only to the backup bucket if possible.

Cloudflare will show:

- Access Key ID
- Secret Access Key
- S3 endpoint

Copy them immediately into your password/secrets manager.

Never commit them here.

## 8. Add R2 to Coolify

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

## 9. Backup bucket separation

If this server starts hosting important data, prefer either:

- a dedicated bucket for this VPS; or
- a dedicated prefix/layout per server/app.

Do not reuse application object-storage credentials as backup credentials. Separate credentials reduce the blast radius of a compromised application.

## 10. Optional Cloudflare Tunnel

A Cloudflare Tunnel is possible with Coolify and can send a wildcard route to the Coolify proxy on `http://localhost:80`.

It is **not** the baseline here because the OVH VPS already has a public IP, unlimited traffic and a normal 80/443 reverse-proxy setup is simpler. Add Tunnel only when you have a specific reason, such as hiding the origin completely or avoiding inbound firewall exposure.

## Done when

- [ ] `coolify.example.com` resolves to the VPS
- [ ] dashboard works over HTTPS
- [ ] wildcard DNS exists if wanted
- [ ] Cloudflare proxy mode is deliberate, not accidental
- [ ] SSL mode is Full (strict) when proxied
- [ ] private R2 backup bucket exists
- [ ] R2 token is scoped and stored outside Git
- [ ] Coolify validates R2 successfully

Next: [05. Backups and recovery](05-backup-recovery.md)

## References

- Coolify DNS: https://coolify.io/docs/core/networking/dns
- Coolify domains: https://coolify.io/docs/core/networking/domains
- Coolify R2: https://coolify.io/docs/core/s3-storage/r2
- Coolify Cloudflare protection: https://coolify.io/docs/integrations/security/cloudflare/ddos-protection
