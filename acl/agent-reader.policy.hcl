# Nomad ACL policy `agent-reader` (KSonny4/platform#16, Slice N prerequisite).
#
# Purpose: read-only baseline of Nomad memory usage (job specs, alloc stats,
# logs) for Slice N. Intended holders: automation agents and the humans
# assisting them with the baseline. Holders must NEVER receive a
# submit-capable token; this policy grants no submit path (see denials below).
#
# Finding (verified against the Nomad HTTP API docs,
# https://developer.hashicorp.com/nomad/api-docs/client, 2026-09-26):
# per-alloc RSS/swap comes from `GET /v1/client/allocation/:alloc_id/stats`,
# whose "ACL Required" entry is `namespace:read-job`. The `read-job`
# capability below therefore covers alloc stats; no extra capability is
# needed for them. Task logs come from `/v1/client/fs/logs/:alloc_id`
# (`namespace:read-logs`), alloc file listing/reads use `read-fs`, and node
# totals come from `/v1/client/stats`, which requires `node:read` (node
# block below).
#
# `node { policy = "read" }` uses the `policy` shorthand because the node
# block has no capability list in Nomad ACLs -- there is nothing more
# granular to write. (Inside `namespace` blocks we use an explicit
# `capabilities` list instead, because the `policy = "read"` shorthand there
# would additionally grant read/list of Nomad Variables, which a reader
# token must not have.)
#
# Explicit denials (no such grant exists in this file): submit-job,
# dispatch-job, scale-job, alloc-lifecycle, alloc-exec, alloc-node-exec,
# Nomad Variables (no `variables` block at all), host volumes (no
# `host_volume` block), and no `operator`, `agent`, `quota`, `plugin` or
# `sentinel` block. There is no `policy = "write"` anywhere in this file.
#
# Token escrow (owner only): the client token minted from this policy is
# stored in Bao KV at `secret/projects/nomad/AGENT_READ_TOKEN` (field
# `token`) by scripts/apply-agent-reader-acl.sh, which pipes the SecretID
# on stdin so it never appears in output, logs, or argv. Contract:
# tests/test_acl_agent_reader.py.
namespace "*" {
  capabilities = ["list-jobs", "read-job", "read-logs", "read-fs"]
}

node {
  policy = "read"
}
