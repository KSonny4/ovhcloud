# 03. Install and configure Nomad

Nomad (server + client on the single VPS) is the deployment control
plane. Workloads ship as jobspec files via `nomad job run`; secrets are
rendered from OpenBao at deploy time, never baked into images or Git.
Live cluster reference: `https://nomad.pkubelka.cz` (Cloudflare Access
OTP as `ksonny4@gmail.com`) → edge TLS → tunnel → `localhost:4646`.

## 1. Install (single node)

1. Install the Nomad binary (pinned release) plus a systemd unit; data
   dir under `/opt/nomad/data`, config in `/etc/nomad.d/`.
2. Server config: `server.enabled = true`, `bootstrap_expect = 1`;
   client config: `client.enabled = true`. Bind HTTP/RPC/Serf
   (4646/4647/4648) to loopback only — the UI/API is served through the
   Cloudflare Tunnel hostname, never direct.
3. Docker driver enabled on the client (Docker comes from the bootstrap
   stage, never Snap).

## 2. Secure and escrow

1. Enable ACLs and run `nomad acl bootstrap` once; escrow the bootstrap
   token in OpenBao (recovery-critical: without it the cluster cannot be
   re-administered after a rebuild).
2. Set and escrow the gossip encryption key in OpenBao alongside the
   token. No secret material in Git — names/placeholders only.
3. Close direct 4646/4647/4648 at the firewall after the tunnel-served
   UI verifies (see [02](02-host-bootstrap.md) for the firewall stage).

## 3. Ship a workload

Minimal jobspec (`jobs/myapp.nomad.hcl`):

```hcl
job "myapp" {
  datacenters = ["ovh-vps"]
  group "app" {
    count = 1
    task "web" {
      driver = "docker"
      config { image = "nginx:alpine" }
      resources { cpu = 200; memory = 128 }
      service {
        name = "myapp"
        port = "http"
        check { type = "http"; path = "/"; interval = "30s"; timeout = "5s" }
      }
    }
  }
}
```

- Secrets: render via `template` stanza from OpenBao at deploy time
  (pattern in [07](07-omniroute.md)).
- Deploy: `nomad job run jobs/myapp.nomad.hcl`; status:
  `nomad job status myapp`. Roll back with `nomad job revert myapp`.
- Expose publicly: DNS CNAME + tunnel ingress route for the hostname
  (same pattern as existing routes), then verify the `https://` URL
  serves through Cloudflare ([04](04-cloudflare.md)).

## 4. Edge routing

The `edge-proxy` job (`jobs/edge-proxy.nomad.hcl`, Traefik with the Nomad
provider) listens on loopback `:80` and routes by Host to backing services
— app jobs opt in with `traefik.enable=true` + a Host rule tag (see
`jobs/registry.nomad.hcl`). The tunnel ingress sends every application
hostname to `localhost:80`; no app port is published publicly.

Stateful jobs use Nomad host volumes declared client-side by
`provision-nomad.sh` (e.g. `registry-data` → `/opt/nomad-volumes/...`).
Secret files (htpasswd) are rendered from OpenBao escrow at deploy time,
memory-only, never committed.

## 5. Back up the cluster

Schedule `nomad operator snapshot save` to the host backup plane → R2
(see [05](05-backup-recovery.md)). A snapshot holds cluster state only —
app volumes/databases ride the same timer separately. A backup untested
by restore is not trusted.

## Done when

- [ ] Nomad server + client healthy on one node (`nomad server members`,
      `nomad node status` show one alive server/client)
- [ ] ACL bootstrap token + gossip key escrowed in OpenBao
- [ ] UI serves `https://nomad.<zone>`, direct 4646/4647/4648 closed
- [ ] a canary job deploys, serves through the tunnel, and reverts
- [ ] snapshots scheduled and one restore probed

Next: edge and backups are provisioner stages; see [04](04-cloudflare.md)
and [05](05-backup-recovery.md).
