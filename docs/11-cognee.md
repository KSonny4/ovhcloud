# 11. Cognee on Nomad (migrated 2026-09-19)

Cognee (server + MCP + Caddy edge) moved from the old VPS to the new host.
Spec authoritative: `KSonny4/cognee-setup` — `jobs/cognee.nomad.hcl` here is
vendored from that repo (see header). Fabric/OmniRoute were retired, not migrated.

## Shape

Single job `cognee`, one group, `count = 1`: `server` (owns
`/cognee-storage`, single-writer SQLite/LanceDB/Kuzu) + `mcp` (stateless API
mode) + `edge` (Caddy basic-auth, the only tunnel target). All ports dynamic
loopback; TCP service checks (HTTP would 401). Images digest-pinned in the
private registry (`cognee`, `cognee-mcp`, `caddy`, all `:2026-09-19`).

## State

`/opt/nomad-volumes/cognee` (uid 1000), bind-mounted (no host_volume stanza,
no agent restart). Migrated 2026-09-19 via stop → tar → checksum → unpack
(byte-identical: 2115 files). The in-job `bootstrap` prestart recreates the
dir on fresh hosts.

## Deploy

Vars arrive at the deploy edge from OpenBao (never Git, never logged):

- `secret/projects/cognee/env`: `llm_api_key`, `service_key`, `jwt_secret`
- `secret/projects/cognee/edge`: `password` → bcrypt via
  `docker run --rm -i <caddy-pin> caddy hash-password` (needs trailing newline)

```bash
nomad job run -var="llm_api_key=..." -var="cognee_api_key=..." \
  -var="edge_hash=..." -var="jwt_secret=..." jobs/cognee.nomad.hcl
```

Prove (see cognee-setup `scripts/deploy.sh` pattern): scheduler-assigned
loopback sockets are ours, edge anon → 401, authed → `cognee edge ok`, then
MCP + REST smokes (`smoke_recall.py`, LLM-free CHUNKS recall).

## Tunnel + DNS

`cognee.pkubelka.cz` ingress tracks the dynamic edge port — re-point after
EVERY redeploy (adapted `point-tunnel.py` against the new tunnel), then adopt
the rule into Terraform so the next apply does not revert it (old drift trap).

## Cluster tokens

New cluster: `secret/projects/nomad/NOMAD_BOOTSTRAP` (`acl_token`). Old
cluster: `secret/projects/nomad/NOMAD_BOOTSTRAP_PRESERVED` (rescued 2026-09-19
after a runner `kv put` clobbered the shared entry; runner now merges).
