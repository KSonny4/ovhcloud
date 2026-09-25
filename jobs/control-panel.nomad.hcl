# Control-panel on Nomad (resurrected 2026-09-19 onto the new VPS).
#
# Image rescued from the decommissioned old host's registry blobs and
# re-pushed: registry.pkubelka.cz/control-panel:restored-20260919
# (digest below). Boot contract measured from the bundle 2026-09-19:
# node dist/src/server.js; CONTROL_PANEL_PORT (default 8080);
# CONTROL_PANEL_HOST defaults 127.0.0.1 (loopback by default — kept);
# CONTROL_PANEL_DATA defaults ./data/state.json (mounted to a host dir so
# state.json survives restarts); projects/static-services configs default
# to ./config/*.json baked into the image. No sqlite/pg driver in the
# bundle: state is file-based; old state.json was container-local on the
# dead host and is GONE — this boots fresh.
#
# Secrets arrive as HCL2 vars at the deploy edge (values from OpenBao, never
# logged). Unknown/optional integrations ship EMPTY (see TODOs): the app
# boots and serves; Cloudflare/GitHub/Grafana/Nomad features stay inert
# until wired. Public hostname control.pkubelka.cz is a parent-phase tunnel
# ingress re-point (DNS already CNAMEs the retired tunnel).
#
# Deploy: bash scripts/deploy-control-panel.sh [--apply]
#   (Grafana token from OpenBao; every other secret carried over from the
#   live job, so a redeploy never empties one.)
# Roll back: nomad job revert control-panel

variable "cf_dns_api_token" {
  type        = string
  default     = ""
  description = "TODO: CF_DNS_API_TOKEN (OpenBao secret/projects/nomad/ADMIN_CLOUDFLARE field ADMIN_CLOUDFLARE). Empty = Cloudflare features inert."
}

variable "cf_access_client_id" {
  type        = string
  default     = ""
  description = "TODO: CF_ACCESS_CLIENT_ID (OpenBao secret/projects/nomad/EDGE_ACCESS_SERVICE_TOKEN field client_id). Empty = Access-protected fetches inert."
}

variable "cf_access_client_secret" {
  type        = string
  default     = ""
  description = "TODO: CF_ACCESS_CLIENT_SECRET (same escrow, field client_secret). Empty = Access-protected fetches inert."
}

variable "github_token" {
  type        = string
  default     = ""
  description = "TODO: GITHUB_TOKEN (user-held, repo-scan scope). Empty = engineering-repo scanning inert."
}

variable "grafana_sa_token" {
  type        = string
  default     = ""
  description = "GRAFANA_SERVICE_ACCOUNT_TOKEN: meowlabs stack service-account token (OpenBao secret/projects/nomad/GRAFANA_SERVICE_ACCOUNT_TOKEN field value, non-expiring). Empty = Grafana panels inert."
}

variable "unleash_admin_token" {
  type        = string
  default     = ""
  description = "UNLEASH_ADMIN_TOKEN: Unleash Admin API token (OpenBao secret/projects/unleash/server field admin_token). Empty = automatization toggles inert."
}

variable "unleash_url" {
  type        = string
  default     = "https://unleash.pkubelka.cz"
  description = "UNLEASH_URL: Unleash server base URL (no /api suffix; the client appends admin paths)."
}

variable "nomad_token" {
  type        = string
  default     = ""
  description = "TODO: NOMAD_TOKEN (fresh scoped token on the new cluster). Empty = Nomad-backed features inert."
}

variable "ingest_token" {
  type        = string
  default     = ""
  description = "TODO: CONTROL_INGEST_TOKEN (shared secret with ingest clients). Empty = ingest auth open/inert per app default."
}

job "control-panel" {
  datacenters = ["ovh-vps"]
  type        = "service"

  group "control-panel" {
    count = 1

    # Cloudflare's control ingress uses this fixed loopback origin port
    # (infra/terraform/main.tf). A dynamic port changed on every allocation
    # and left control.pkubelka.cz answering 502 (2026-09-25).
    network {
      port "http" {
        host_network = "loopback"
        static       = 30811
      }
    }

    # Host-dir bootstrap: image runs as node (uid 1000); docker auto-creates
    # a missing bind source as root, which node cannot write. Prestart
    # sidecar owns the mkdir/chown (cognee pattern).
    task "bootstrap" {
      driver = "docker"

      config {
        image = "registry.pkubelka.cz/caddy:2026-09-19@sha256:d8c17a862962def15cde69863a3a463f25a2664942eafd7bdbf050e9c3116b83"
        volumes = [
          "/opt/nomad-volumes:/vol",
        ]
        args = [
          "sh", "-c",
          "mkdir -p /vol/control-panel && chown 1000:1000 /vol/control-panel && ls -ld /vol/control-panel",
        ]
      }

      user = "root"

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      resources {
        cpu    = 100
        memory = 48
      }
    }

    task "server" {
      driver = "docker"

      config {
        network_mode = "host"
        image = "registry.pkubelka.cz/control-panel:ui-978bf11@sha256:961b7db9bb381b2ab7f506a576ce1cf89f55b5d810264cb9fe3ac5d613a0e9b6"
        ports = ["http"]

        volumes = [
          "/opt/nomad-volumes/control-panel:/app/data",
        ]
      }

      env {
        NODE_ENV              = "production"
        # Loopback-only bind (host netns): app default is 127.0.0.1, made
        # explicit; port is scheduler-assigned (see group).
        CONTROL_PANEL_HOST    = "127.0.0.1"
        CONTROL_PANEL_PORT    = "${NOMAD_PORT_http}"
        CONTROL_PANEL_DATA    = "/app/data/state.json"
        CONTROL_PANEL_URL     = "https://control.pkubelka.cz"
        CONTROL_HOST_NAME     = "vps-c85da816"
        NOMAD_ADDR            = "http://127.0.0.1:4646"
        GRAFANA_URL           = "https://meowlabs.grafana.net"
        # Secrets (see vars): empty ones keep their feature inert.
        CF_DNS_API_TOKEN            = "${var.cf_dns_api_token}"
        CF_ACCESS_CLIENT_ID         = "${var.cf_access_client_id}"
        CF_ACCESS_CLIENT_SECRET     = "${var.cf_access_client_secret}"
        GITHUB_TOKEN                = "${var.github_token}"
        GRAFANA_SERVICE_ACCOUNT_TOKEN = "${var.grafana_sa_token}"
        NOMAD_TOKEN                 = "${var.nomad_token}"
        CONTROL_INGEST_TOKEN        = "${var.ingest_token}"
        UNLEASH_ADMIN_TOKEN         = "${var.unleash_admin_token}"
        UNLEASH_URL                 = "${var.unleash_url}"
      }

      resources {
        cpu    = 250
        memory = 512
      }

      service {
        name     = "control-panel"
        port     = "http"
        provider = "nomad"

        # TCP liveness (registry pattern): endpoint auth surface unknown,
        # so http checks could false-fail; real proof is the loopback
        # body check post-deploy.
        check {
          type     = "tcp"
          interval = "15s"
          timeout  = "3s"
        }
      }
    }
  }
}
