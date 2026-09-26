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

- Secrets: render via `-var-file` from OpenBao at deploy time
  (example: `jobs/registry.nomad.hcl` + `docs/09-docker-registry.md`).
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

## 6. Agent read-only access (agent-reader)

Slice N agents need a read-only memory baseline (job specs, alloc
RSS/swap, logs) without ever holding a submit-capable token. The
`agent-reader` ACL policy (`acl/agent-reader.policy.hcl`) grants exactly:

- namespace `*`: `list-jobs`, `read-job` (covers per-alloc stats via
  `/v1/client/allocation/:alloc_id/stats`), `read-logs`, `read-fs`;
- `node { policy = "read" }` for node totals (the node block has no
  capability list, so the shorthand is the only spelling).

It denies everything else: no `submit-job`/`dispatch-job`/`scale-job`,
no alloc lifecycle/exec, no Nomad Variables, no host volumes, no
`operator`/`agent`/`quota`/`plugin`/`sentinel`, and no `policy = "write"`
anywhere. Contract: `tests/test_acl_agent_reader.py`
(`python3.14 -m unittest discover -s tests -p 'test_acl_*.py'`).

Owner apply (owner only, never an agent lane):

```bash
NOMAD_ADDR=... NOMAD_TOKEN=<management> BAO_ADDR=... \
  bash scripts/apply-agent-reader-acl.sh --apply
```

`--dry-run` is the default. `--apply` applies the policy, mints one
`agent-reader` client token (TTL from `AGENT_READER_TTL`, default `720h`;
needs the server's `acl.token_max_expiration_ttl` raised accordingly, else
the mint fails closed), pipes the SecretID into Bao KV at
`secret/projects/nomad/AGENT_READ_TOKEN` (field `token`), and prints only
the accessor ID and the Bao path.

Agent consumption: read the token into `NOMAD_TOKEN` for a single process
only — never export it, never write it to history or files:

```bash
NOMAD_TOKEN="$(bao kv get -field=token secret/projects/nomad/AGENT_READ_TOKEN)" \
  nomad job status <job>
```

## 7. Absorbed from NomadSetup

The single-node agent setup was absorbed from the (read-only) `NomadSetup`
repository (Refs #15). `config/nomad.hcl` is now the single committed Nomad
agent config: `scripts/provision-nomad.sh` installs it verbatim and only
adds the provision-time secrets (gossip file, Docker auth file) on the host.
The absorbed file keeps the dump host volumes, the Docker driver auth
reference, and the gossip mechanism (separate 0600 file from
`NOMAD_GOSSIP_KEY`, never committed). The source file contained no literal
secrets, so no placeholder substitution was needed.

| Old NomadSetup path | New platform path / disposition |
|---|---|
| `config/nomad.hcl` | `config/nomad.hcl` (single committed agent config) |
| `scripts/registry-chunked-push.py` | `scripts/registry-chunked-push.py` (verbatim copy) |
| `scripts/install-nomad.sh` | dropped, duplicate of `scripts/provision-nomad.sh` |
| `scripts/bootstrap-acl.sh` | dropped, duplicate of the ACL-bootstrap section in `scripts/provision-nomad.sh` |
| `scripts/verify.sh` | dropped, duplicate of `scripts/verify-nomad-live.sh` |
| `config/nomad.service` | dropped, duplicate of the systemd unit embedded in `scripts/provision-nomad.sh` |
| `jobs/registry.nomad.hcl` | dropped, duplicate of `jobs/registry.nomad.hcl` (platform copy is the evolved one) |

## 8. Agent telemetry → Grafana Cloud (Slice N, Refs #16)

The agent config (`config/nomad.hcl`) enables Prometheus telemetry so the
Slice N right-size pass has real usage history:

```hcl
telemetry {
  collection_interval        = "10s"
  disable_hostname           = true
  prometheus_metrics         = true
  publish_allocation_metrics = true
  publish_node_metrics       = true
}
```

The `nomad-metrics-alloy` job (`jobs/nomad-metrics-alloy.nomad.hcl`)
scrapes `http://127.0.0.1:4646/v1/metrics?format=prometheus` every 30s and
`remote_write`s to Grafana Cloud (`prometheus-prod-55-...`). No Nomad token
is needed for the scrape: `/v1/metrics` requires no ACL (Nomad HTTP API
docs: "ACL Required: none"; verified live — an unauthenticated GET reached
the endpoint). The Cloud write token arrives via `-var` from Bao
(`secret/projects/nomad/GRAFANA_CLOUD_RW2`, field `token`), never in Git.

Apply (owner/operator edge; no lane ever applies):

1. Ship the config: `scripts/provision-nomad.sh` installs
   `config/nomad.hcl` as `/etc/nomad.d/nomad.hcl`, then
   `systemctl restart nomad`. Running allocations survive an agent
   restart. Verify: `curl http://127.0.0.1:4646/v1/metrics?format=prometheus`
   returns series (before telemetry it answers 415 "Prometheus is not
   enabled").
2. Submit the scraper with the Cloud token from Bao:
   `nomad job run -var="grafana_cloud_rw2_token=$(bao kv get -field=token secret/projects/nomad/GRAFANA_CLOUD_RW2)" jobs/nomad-metrics-alloy.nomad.hcl`.
   Telemetry must be applied first — until step 1 the scrape 415s.

Roll back: `nomad job stop nomad-metrics-alloy` stops shipping (history
already in Cloud stays queryable); to silence the endpoint, remove the
`telemetry` block, reship the config, and restart the agent again.

## 9. Watcher-only deploys + agent sandbox (Slice 4, Refs #26)

Git `main` is the only way to change a production job: only the watcher's
token may submit there, and agents get a `sandbox` namespace for
experiments. All of this is committed but NOT applied in the slice —
the owner applies it after Slice 1 proves the watcher (runbook:
[acl-cutover-runbook](acl-cutover-runbook.md)).

- `acl/namespaces.json` is the single data file for namespace names
  (production: `default`); policies, specs, script and test derive from it.
- `acl/deployer.policy.hcl`: watcher only (`list-jobs, read-job,
  parse-job, submit-job, read-logs` per production namespace + node read).
- `acl/agent-sandbox.policy.hcl`: agents (`submit-job, dispatch-job,
  read-job, list-jobs, read-logs`) ONLY in `sandbox`.
- `acl/namespace-sandbox.hcl` + `jobs/sandbox-sweep.nomad.hcl`
  (committed spec, stops sandbox jobs after 24h; never `job run` by hand).
- Quotas and namespace pool pins are Enterprise-only, so this OSS cluster
  takes the documented branch: 1024 MB memory cap + per-job
  `node_pool = "home"` pin (Slice P) instead of server-side enforcement.
- `scripts/apply-acl-s4.sh` (`--dry-run` default; `--apply` mints TTL
  tokens into `secret/projects/nomad/WATCHER_DEPLOY_TOKEN` and
  `secret/projects/nomad/AGENT_SANDBOX_TOKEN` without printing).
  Contract: `tests/test_acl_s4.py`.

The Bao cutover (revoke agent read on `NOMAD_BOOTSTRAP`, break-glass the
management token, rotate it) is a later [YES] step, written as runbook
section 4 only.

## Done when

- [ ] Nomad server + client healthy on one node (`nomad server members`,
      `nomad node status` show one alive server/client)
- [ ] ACL bootstrap token + gossip key escrowed in OpenBao
- [ ] UI serves `https://nomad.<zone>`, direct 4646/4647/4648 closed
- [ ] a canary job deploys, serves through the tunnel, and reverts
- [ ] snapshots scheduled and one restore probed

Next: edge and backups are provisioner stages; see [04](04-cloudflare.md)
and [05](05-backup-recovery.md).
