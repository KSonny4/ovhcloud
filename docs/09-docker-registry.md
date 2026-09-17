# 09. Private Docker registry on Coolify

A private Docker registry (`registry:2`) running as a Coolify application (dashboard Path A: **New Resource → Application → Docker Image**). It stores private images for workloads deployed through Coolify; pulls and pushes go over the Cloudflare Tunnel, so the VPS still opens no public web ports.

Its public hostname must use the approved canonical domain recorded in `docs/deployment-plan.md`; `example.com` below is only a documentation placeholder.

## Target architecture

```text
docker push/pull clients
      |
Cloudflare DNS + proxy/TLS (registry.pkubelka.cz)
      |
Cloudflare Tunnel coolify-admin -> localhost:80
      |
Coolify reverse proxy (Traefik, routes by Host)
      |
registry:2 :5000 (/v2/ API)
      |
/var/lib/registry persistent volume
      |
      `-- covered by the existing volume/R2 backup path (docs/05-backup-recovery.md)
```

## 1. No Cloudflare Access app

Do NOT front the registry hostname with a Cloudflare Access policy. Docker clients are machines, not interactive users — the same rule as the OmniRoute API hostnames (`omni.`/`omniroute.`). Access would break `docker login`/`push`/`pull`. Authentication is the registry's own htpasswd auth (section 3); TLS is the Cloudflare edge.

## 2. Coolify deploy steps (Path A)

Dashboard → `production` environment → **New Resource → Application → Docker Image**:

- Image: `registry:2` (pin a digest once chosen; record it in the operator's secure notes, not here).
- Container port: `5000`; domain: `registry.<approved-domain>` (e.g. `registry.pkubelka.cz`).
- Persistent volume: mount at `/var/lib/registry` (single replica only — the filesystem storage backend assumes one writer).
- Environment:
  - `REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY=/var/lib/registry`
  - `REGISTRY_AUTH=htpasswd`
  - `REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm`
  - `REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd`
  - `REGISTRY_HTTP_HOST=https://registry.<approved-domain>` — REQUIRED behind the Tunnel: edge TLS terminates at Cloudflare while the registry sees plain HTTP, so without this it mints `http://` upload URLs and every push fails auth on resume. This was the live failure on 2026-09-17.
- Mount the htpasswd file at `/auth/htpasswd` (read-only). Its content lives in OpenBao at `secret/projects/ovhcloud/REGISTRY` (key names only here — never values, never in Git); copy it onto the mount through the operator's secure channel at deploy time.
- Resource limits: this is a small host — set CPU/memory limits so large pushes cannot starve neighboring apps.

## 3. htpasswd creation and escrow

Generate credentials off-host (bcrypt format, as required by `registry:2`):

```bash
docker run --rm --entrypoint htpasswd httpd:2 -Bbn <username> <password>
```

Escrow the resulting file content in OpenBao at `secret/projects/ovhcloud/REGISTRY` (memory-only handling, fail closed). Rotation: generate a new file, update the escrow entry, redeploy the Coolify app, then verify `docker login` with the new credentials and revoke the old ones.

## 4. Large-layer push tolerance

`docker push` of large layers needs proxy tolerance for long-lived, chunked request bodies along the whole path (client → Cloudflare edge → cloudflared → Traefik → registry):

- Prefer chunked push behavior (default in modern Docker clients); avoid proxy buffering that spools entire layers to disk or times out idle streams.
- If pushes stall or reset, check Traefik request timeouts/body handling on the Coolify reverse proxy and cloudflared idle-stream behavior before blaming the registry — `registry:2` itself accepts arbitrarily large layers when the path passes them through.
- Keep pushes on a reliable link for the first large image; once stored, pulls are ordinary GETs.

## 5. Verification

Unauthenticated catalog check (expect `401` with htpasswd on, `200 {}` with auth off):

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://registry.<approved-domain>/v2/
```

Authenticated smoke (proves the full push/pull path through Tunnel + proxy):

```bash
docker login registry.<approved-domain>
docker pull hello-world:latest
docker tag hello-world:latest registry.<approved-domain>/smoke/hello-world:latest
docker push registry.<approved-domain>/smoke/hello-world:latest
docker rmi registry.<approved-domain>/smoke/hello-world:latest
docker pull registry.<approved-domain>/smoke/hello-world:latest
```

Delete the `smoke/` test repository afterwards via the registry API so test blobs do not accumulate.

## 6. DNS / tunnel / IaC status

Terraform (plan-only) already declares the `registry.<domain>` CNAME and the tunnel ingress route — same origin-proxy pattern as the other application hostnames, no Access app. A human may apply them only through the authorized-apply sequence in `docs/deployment-plan.md`; validation here never runs `terraform apply`.

## 7. Live deployment record (2026-09-17)

Deployed and proven live the same day via Coolify + Cloudflare APIs (no browser available in the automation session):

- Coolify app `registry` (`uttlrzcrskrudfpwuxfhml3e`), project `omniroute`, environment `production`, server `localhost`; image `registry:2.8.3`, port `5000`, persistent volume `/var/lib/registry`, htpasswd file mount `/auth/htpasswd` (content from OpenBao escrow).
- Cloudflare: proxied CNAME `registry` → `coolify-admin` tunnel hostname; tunnel ingress `registry.${domain} → http://localhost:80` inserted before the catch-all (prior config backed up before the change).
- Live proof: `docker login` OK, pushed `hello-world`, deleted all local copies, pulled back digest-identical (`sha256:5099b89d…`), container ran (`Hello from Docker!`), catalog listed the repo. Proof repo removed afterwards; credentials scrubbed from the operator machine.
- Two API-path gotchas recorded for the next operator: (a) the public Coolify API has no domains endpoint, and Coolify does not generate Traefik routers from the `fqdn` string on docker-image apps — the Host router (`traefik.enable`, `traefik.docker.network`, gzip middleware, Host+PathPrefix rule, port-5000 service) was supplied via base64 `custom_labels` and took effect on redeploy; (b) `REGISTRY_HTTP_HOST` is mandatory (see section 2).
- Escrow `secret/projects/ovhcloud/REGISTRY` now holds `htpasswd`, `http_secret`, `username`, `password` (plaintext kept for smoke/rotation verify; vault-only, never Git).
- **Terraform drift note:** DNS + tunnel ingress were created via Cloudflare API, outside Terraform state. Before the next `terraform apply`, the operator must import both (exact resource addresses in `infra/terraform/main.tf`):

```bash
terraform import cloudflare_dns_record.registry <zone-id>/9c52c9d1820697c9111b58b05bf96bbf
terraform import cloudflare_zero_trust_tunnel_cloudflared_config.admin <account-id>/<tunnel-id>
```

  then `terraform plan` must show no changes. IDs above are the live objects created 2026-09-17 (zone/account/tunnel IDs per the existing configuration).
- **Duplicate note:** a separate `docker-registry` project (service `registry`, image `registry:3`) already exists on the host, predating this deployment. Consolidate on one registry later; the proven one is this app (`registry.pkubelka.cz`, `registry:2.8.3`).
