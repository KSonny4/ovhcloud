# Slice 4 ACL runbook: watcher-only deploys + agent sandbox (KSonny4/platform#26)

Repo part of plan Slice 4. Nothing in this file is applied by merging it:
every live step below is owner-run (later **[YES]**), in order.

## 1. What this slice added (committed, not applied)

| Artifact | Role |
|---|---|
| `acl/namespaces.json` | Single data file: production namespaces (`default`), sandbox name, pool pin, memory cap, max age. Policies, specs, script and test derive from it. |
| `acl/deployer.policy.hcl` | Watcher-only: `list-jobs, read-job, parse-job, submit-job, read-logs` per production namespace + `node read`. No dispatch, no Variables, no `policy = "write"`. |
| `acl/agent-sandbox.policy.hcl` | Agents: `submit-job, dispatch-job, read-job, list-jobs, read-logs` ONLY in `sandbox`. No production block, no node block, no stop/scale. |
| `acl/namespace-sandbox.hcl` | Namespace spec (name, description, meta with the constraints). |
| `jobs/sandbox-sweep.nomad.hcl` | Periodic batch (every 30 min, UTC) that stops sandbox jobs older than 24h. Committed only, runs in `default` with a privileged token injected at deploy time. |
| `scripts/apply-acl-s4.sh` | Idempotent apply, dry-run by default; `--apply` creates TTL tokens and escrows them to Bao without printing. |
| `tests/test_acl_s4.py` | Contract test (`python3.14 -m unittest discover -s tests -p 'test_acl_*.py'`). |

Existing `acl/agent-reader.policy.hcl` and its script/test are untouched.

## 2. Sandbox constraints (documented)

- **Quota:** Nomad resource quotas are Enterprise-only (namespace `quota`
  field and the quota spec API; verified against the official namespace and
  quota spec docs, 2026-09-26). This OSS cluster takes the documented-cap
  branch instead: `sandbox` carries a **1024 MB total memory cap**
  (`acl/namespaces.json` → namespace meta), enforced by review plus the
  sweep job. If the cluster ever moves to Enterprise, attach a quota spec
  and set the `quota` line — the test's `test_no_quota_line` will then need
  updating deliberately.
- **Sweep:** `jobs/sandbox-sweep.nomad.hcl` stops (not purges) sandbox jobs
  older than `sandbox_max_age_hours` (24h). Adopted by the watcher after
  Slice 3; until then an owner may run the embedded logic by hand in a
  drill only.
- **Root-on-node risk:** a submit-job token is effectively root on the node
  it lands on while Docker bind mounts are enabled on the client. That is
  why sandbox compute must never share the production node.
- **`home` pool pin:** `node_pool_config` is likewise Enterprise-only, so
  the pin cannot be enforced at namespace level here. Rule until it can:
  every sandbox job spec sets `node_pool = "home"` (the Pi client,
  Slice P); production jobs set `node_pool = "default"`.

## 3. Owner apply (later [YES], after Slice 1 proves the watcher)

```bash
# 1. Read the plan; it changes nothing.
bash scripts/apply-acl-s4.sh --dry-run
# 2. Apply (needs NOMAD_ADDR/NOMAD_TOKEN management + BAO_ADDR session).
NOMAD_ADDR=... NOMAD_TOKEN=... BAO_ADDR=... bash scripts/apply-acl-s4.sh --apply
```

`--apply` is idempotent for namespace + policies; token mints are
rotations (fresh SecretID, escrow entry replaced). TTLs come from
`WATCHER_DEPLOY_TTL` / `AGENT_SANDBOX_TTL` (default `720h`); the mint
fails closed unless the server's `acl.token_max_expiration_ttl` covers it.

## 4. Bao cutover (later [YES] step — runbook only, NOT executed here)

1. Point the watcher at `secret/projects/nomad/WATCHER_DEPLOY_TOKEN` via
   its workload identity/AppRole (readable only by the watcher).
2. Point agents at `secret/projects/nomad/AGENT_SANDBOX_TOKEN` (sandbox)
   and the existing `secret/projects/nomad/AGENT_READ_TOKEN` (read-only).
3. Remove the agent AppRole's read on `secret/projects/nomad/NOMAD_BOOTSTRAP`
   (and on the stale `secret/projects/NomadSetup/acl` path).
4. Move the management token under an owner-only `break-glass` Bao policy
   with audit logging on.
5. Rotate the management token (agents have read the old one), then verify:
   agent AppRole gets 403 on `NOMAD_BOOTSTRAP`; the old management token
   no longer works.

## 5. Verification (ACL proof, at cutover time)

- With an agent token, `nomad job run` and `curl -XPOST /v1/jobs` return
  **403** in production namespaces, while `job status` and alloc logs work.
- With an agent token, `nomad job run -namespace=sandbox` succeeds (once
  the `home` pool exists; before Slice P it schedules on the only node —
  sandbox use stays minimal until the pin is real).
- With the watcher token, a PR merge still deploys.
- The rotated management token works only via break-glass.

## 6. Rollback

- Policies/namespace: re-apply the previous policy text; `nomad namespace`
  cannot be deleted while jobs reference it — stop sandbox jobs first.
- Tokens: `nomad acl token delete <accessor>` (accessors are the only IDs
  the apply script prints); rotate the escrow entries by re-running
  `--apply`.
