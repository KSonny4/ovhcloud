# Flags automation on Nomad (listener + nightly scan + stale-ticket sync).
#
# Image pinned to the rescued tag (old-registry archive, re-pushed
# 2026-09-19): registry.pkubelka.cz/eg-flags:restored-20260919
# (digest sha256:f7511f9e0f61a850d70d20bbcb54846531ba3584208b5cf26801ccc46e818d3d).
# Scripts live at /app (flags-listener.py, flags-pr-scan.py,
# unleash-stale-tickets.py); collectors import from /app/eg_collectors.
# Needs the `gh` CLI (baked in image) + GH_TOKEN for posts.
#
# Secrets are job VARIABLES (no defaults for tokens): pass at deploy time
# via -var (memory only, never committed):
#   nomad job run \
#     -var="webhook_secret=..." -var="gh_token=..." \
#     -var="unleash_admin_token=..." jobs/flags.nomad.hcl
# Without webhook_secret the webhook endpoint 401s but /healthz stays 200.
# Without --config the listener serves with zero repos (verdicts need a
# repos.json mounted later; checkpoint defaults to the alloc dir).
#
# Deploy: nomad job run -var=... jobs/flags.nomad.hcl
# Roll back: nomad job revert flags-listener / flags-scan / flags-stale
variable "webhook_secret" {
  type        = string
  default     = ""
  description = "FLAGS_WEBHOOK_SECRET for HMAC webhook verification."
}
variable "gh_token" {
  type        = string
  default     = ""
  description = "GH_TOKEN for gh CLI posts."
}
variable "unleash_admin_token" {
  type        = string
  default     = ""
  description = "UNLEASH_ADMIN_TOKEN for the stale-ticket sync."
}
variable "unleash_url" {
  type        = string
  default     = "https://unleash.pkubelka.cz"
  description = "Unleash base URL for batch jobs (public hostname; loopback override once the lane reports a port)."
}
variable "scan_repo" {
  type        = string
  default     = ""
  description = "OWNER/REPO for the nightly flags PR scan (empty = scan task exits 0 without running)."
}

job "flags-scan" {
  datacenters = ["ovh-vps"]
  type        = "batch"

  periodic {
    cron             = "17 3 * * *"
    prohibit_overlap = true
  }

  group "scan" {
    count = 1

    task "scan" {
      driver = "docker"

      config {
        network_mode = "host"
        image      = "registry.pkubelka.cz/eg-flags:restored-20260919@sha256:f7511f9e0f61a850d70d20bbcb54846531ba3584208b5cf26801ccc46e818d3d"
        entrypoint = ["/bin/sh", "-c"]
        args = [
          "if [ -z \"$SCAN_REPO\" ]; then echo 'scan_repo unset, skipping'; exit 0; fi; exec python3 /app/flags-pr-scan.py --repo \"$SCAN_REPO\" --days 14",
        ]
      }

      env {
        GH_TOKEN  = var.gh_token
        SCAN_REPO = var.scan_repo
      }

      resources {
        cpu    = 200
        memory = 256
      }
    }
  }
}

