# Nomad ACL policy `agent-sandbox` (KSonny4/platform#26, Slice 4;
# owner decision 2026-09-26: agents get a sandbox namespace).
#
# Purpose: the ONE place agents may run `nomad job run` for experiments and
# previews — the `sandbox` namespace only (acl/namespaces.json). Intended
# holders: automation agents and the humans assisting them.
#
# Capabilities (explicit list, never the `policy` shorthand): submit-job,
# dispatch-job, read-job, list-jobs, read-logs — and ONLY in `sandbox`.
# There is deliberately no block for any production namespace, no node
# block, no `operator`/`agent`/`quota`/`plugin`/`host_volume`/`variables`/
# `sentinel` block, and no `policy = "write"` anywhere in this file.
# Note there is no stop-job/scale-job here either: jobs age out via the
# sweep spec (jobs/sandbox-sweep.nomad.hcl), which runs outside sandbox
# with a privileged token.
#
# Documented risk: a submit-job token is effectively root on the node it
# lands on while Docker bind mounts are enabled. Containment is the `home`
# node-pool pin (Slice P): every sandbox job spec MUST set
# `node_pool = "home"` so experiments never land on the production node.
# Full rationale: docs/acl-cutover-runbook.md.
#
# Token escrow (owner only, later [YES] step): scripts/apply-acl-s4.sh
# --apply mints the token and pipes the SecretID on stdin so it never
# appears in output, logs, or argv. Bao KV:
# `secret/projects/nomad/AGENT_SANDBOX_TOKEN` (field `token`).
# Contract: tests/test_acl_s4.py.
namespace "sandbox" {
  capabilities = ["submit-job", "dispatch-job", "read-job", "list-jobs", "read-logs"]
}
