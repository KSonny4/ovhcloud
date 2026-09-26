# Nomad namespace spec `sandbox` (KSonny4/platform#26, Slice 4).
#
# The agent experiment namespace. Applied once by the owner with
# `nomad namespace apply acl/namespace-sandbox.hcl` (via
# scripts/apply-acl-s4.sh --apply); re-applying is idempotent. The
# namespace name is data: acl/namespaces.json ("sandbox"). HCL1 only:
# namespace specs do not support HCL2 functions.
#
# Constraints (full rationale in docs/acl-cutover-runbook.md):
# - Quota: Nomad resource quotas are Enterprise-only (verified against
#   https://developer.hashicorp.com/nomad/docs/other-specifications/quota,
#   2026-09-26), so NO `quota` line is set here. The cap is a documented
#   memory cap instead (meta.memory_cap_mb, 1024 MB total for the
#   namespace), enforced by review plus the sweep job below.
# - Node-pool pin: `node_pool_config` is likewise Enterprise-only on this
#   OSS cluster, so the `home` pin cannot be enforced at namespace level.
#   Every sandbox job spec MUST set `node_pool = "home"` (Slice P);
#   tests/test_acl_s4.py asserts the committed sweep-adjacent specs do.
# - Max age: jobs older than meta.max_age_hours (24h) are stopped by the
#   committed sweep spec jobs/sandbox-sweep.nomad.hcl (committed only,
#   NOT deployed in this lane).
# - Root-on-node risk: submit-job is effectively root on the target node
#   while Docker bind mounts are enabled; that is why sandbox is pinned
#   to `home` (the Pi client), never the production node.
name        = "sandbox"
description = "Agent experiment namespace: the only place agent-held tokens may submit (policy agent-sandbox). Pinned to the home node pool; jobs older than 24h are swept."

meta {
  owner         = "platform"
  node_pool     = "home"
  memory_cap_mb = "1024"
  max_age_hours = "24"
  managed_by    = "nomad-github-watcher"
  acl_policy    = "agent-sandbox"
}
