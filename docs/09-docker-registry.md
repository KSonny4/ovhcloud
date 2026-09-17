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
