# Nomad ACL policy `deployer` (KSonny4/platform#26, Slice 4).
#
# Purpose: watcher-only deploy credential. The nomad-github-watcher holds the
# single client token minted from this policy and is the ONLY writer that may
# submit to production namespaces. Intended holder: the watcher workload
# identity only; NEVER an agent or human token.
#
# Production namespaces are data: acl/namespaces.json ("production"). This
# file carries one block per production namespace; if that file gains a
# namespace, this policy gains a matching block. Namespace names are never
# invented here (enforced by tests/test_acl_s4.py).
#
# Capabilities per production namespace (explicit list, never the
# `policy = "read"` shorthand — the shorthand would additionally grant
# read/list of Nomad Variables, which a deploy token must not have):
# list-jobs + read-job (adopt/drift reads), parse-job (spec validation),
# submit-job (the watcher deploy path), read-logs (deploy diagnosis).
# Deliberately absent: dispatch-job (dispatch stays with narrow per-project
# tokens such as graph-prep-dispatch), scale-job, alloc-lifecycle,
# alloc-exec, Nomad Variables (no `variables` block), and no `operator`,
# `agent`, `quota`, `plugin` or `sentinel` block. There is no
# `policy = "write"` anywhere in this file.
#
# Scoped host_volume exception (KSonny4/forgejo#1): exactly the three
# Forgejo volumes below, each `capabilities = ["mount-readwrite"]` (the
# capabilities spelling — `policy = "write"` stays forbidden everywhere).
# No other host_volume block is allowed here; no host_volume block is
# allowed in any other policy (enforced by tests/test_acl_s4.py).
#
# `node { policy = "read" }` gives the watcher node totals for scheduling
# proof; the node block has no capability list, so the shorthand is the only
# spelling (same reasoning as acl/agent-reader.policy.hcl).
#
# Token escrow (owner only, later [YES] step): scripts/apply-acl-s4.sh
# --apply mints the token and pipes the SecretID on stdin so it never
# appears in output, logs, or argv. Bao KV:
# `secret/projects/nomad/WATCHER_DEPLOY_TOKEN` (field `token`).
# Contract: tests/test_acl_s4.py.
namespace "default" {
  capabilities = ["list-jobs", "read-job", "parse-job", "submit-job", "read-logs"]
}

node {
  policy = "read"
}

host_volume "forgejo-pg-data" {
  capabilities = ["mount-readwrite"]
}

host_volume "forgejo-data" {
  capabilities = ["mount-readwrite"]
}

host_volume "forgejo-runner-data" {
  capabilities = ["mount-readwrite"]
}
