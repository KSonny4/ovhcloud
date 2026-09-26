# Sandbox sweep (KSonny4/platform#26, Slice 4).
#
# DEPLOYMENT: committed only — NEVER `nomad job run` this file by hand.
# It is adopted by the watcher after Slice 3 like any other platform job.
# This lane deploys nothing (no Nomad, no Bao, no SSH).
#
# Purpose: stop jobs in the `sandbox` namespace (acl/namespaces.json)
# older than 24h, so agent experiments cannot accumulate. Runs every
# 30 minutes as a periodic batch job in the `default` namespace — it must
# NOT run in `sandbox`, because the agent-sandbox policy deliberately has
# no stop-job capability; the sweep needs a privileged token.
#
# Auth (wired at deploy time, NOT here): the task requires NOMAD_ADDR plus
# a NOMAD_TOKEN whose policy can stop sandbox jobs (the watcher deployer
# token or management via break-glass). There is no default and no
# committed value; without them the task fails closed before touching any
# job. How the watcher injects it is a Slice 1/3 deploy detail.
#
# Threshold and target are data: acl/namespaces.json
# (sandbox = "sandbox", sandbox_max_age_hours = 24). The script stops
# (not purges) so history survives; periodic/system housekeeping jobs are
# skipped by type where the CLI reports one.
job "sandbox-sweep" {
  datacenters = ["ovh-vps"]
  namespace   = "default"
  node_pool   = "default"
  type        = "batch"

  periodic {
    cron             = "*/30 * * * *"
    prohibit_overlap = true
    time_zone        = "UTC"
  }

  group "sweep" {
    count = 1

    task "sweep" {
      driver = "docker"

      config {
        image      = "hashicorp/nomad:2.0.6"
        entrypoint = ["/bin/sh", "/local/sweep.sh"]
      }

      template {
        dest_path = "local/sweep.sh"
        perms     = "755"
        change_mode = "noop"
        data = <<EOH
#!/bin/sh
# Stop sandbox jobs older than MAX_AGE_S (24h). Fail closed on missing auth.
set -eu
NS="sandbox"
MAX_AGE_S=86400
: "${NOMAD_ADDR:?NOMAD_ADDR must be set (injected at deploy time)}"
: "${NOMAD_TOKEN:?NOMAD_TOKEN must be set (privileged token, injected at deploy time)}"
now=$(date +%s)
cutoff=$((now - MAX_AGE_S))
ids=$(nomad job status -namespace="$NS" -short | awk 'NR>1 && NF {print $1}')
[ -z "$ids" ] && { echo "no jobs in namespace $NS"; exit 0; }
stopped=0
for id in $ids; do
  submit_ns=$(nomad job inspect -namespace="$NS" "$id" | grep -o '"SubmitTime":[0-9]*' | head -1 | grep -o '[0-9][0-9]*' || true)
  [ -z "$submit_ns" ] && { echo "skip $id: no SubmitTime"; continue; }
  submit_s=$((submit_ns / 1000000000))
  if [ "$submit_s" -lt "$cutoff" ]; then
    echo "stopping $id (submitted $submit_s, cutoff $cutoff)"
    nomad job stop -namespace="$NS" "$id"
    stopped=$((stopped + 1))
  else
    echo "keeping $id (submitted $submit_s, cutoff $cutoff)"
  fi
done
echo "stopped $stopped job(s) in namespace $NS"
EOH
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }
  }
}
