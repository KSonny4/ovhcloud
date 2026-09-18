# Fabric stack on Nomad (ported from the retired-plane compose, 2026-09-18).
#
# One group, three tasks sharing loopback: api (:8080) + neo4j (7474/7687)
# + postgres (5432). Stateful data stays in the EXISTING Docker named
# volumes (no migration, no agent restart, no host_volume declarations).
# Secrets arrive as HCL2 variables rendered from OpenBao
# (projects/nomad/FABRIC) by scripts/deploy-fabric.sh at deploy time —
# never committed, never baked into this spec. Retired-plane injected env
# (COOLIFY_*) is deliberately absent: the app reads none of it.
#
# Deploy: bash scripts/deploy-fabric.sh (fail closed on missing escrow)
# Roll back: nomad job revert fabric
# Secrets: every value arrives via -var-file rendered from OpenBao
  # (projects/nomad/FABRIC) by scripts/deploy-fabric.sh at deploy
  # time. No default is safe, so none exists — a missing var fails the
  # submit before anything schedules.
variable "fabric_bearer" {
  type      = string
}
variable "gh_token" {
  type      = string
}
variable "gh_webhook_secret" {
  type      = string
}
variable "omni_key" {
  type      = string
}
variable "neo4j_password" {
  type      = string
}
variable "postgres_password" {
  type      = string
}
variable "r2_access_key_id" {
  type      = string
}
variable "r2_secret_access_key" {
  type      = string
}
variable "r2_account_id" {
  type      = string
}
variable "r2_bucket" {
  type      = string
}
variable "r2_enc_passphrase" {
  type      = string
}
variable "cf_access_client_id" {
  type      = string
}
variable "cf_access_client_secret" {
  type      = string
}

job "fabric" {
  datacenters = ["ovh-vps"]
  type        = "service"


  group "fabric" {
    count = 1

    task "api" {
      driver = "docker"

      config {
        image = "4voakknnfy2e2vah8xt9crnu_fabric-api:a1ae707389733c19c4877427a4431afe5eb648a9"
        ports = ["http"]

        volumes = [
          "4voakknnfy2e2vah8xt9crnu_fabric-state:/state",
        ]
      }

      env {
        SERVICE_FQDN_FABRIC_API = "fabric.pkubelka.cz"
        SERVICE_URL_FABRIC_API  = "https://fabric.pkubelka.cz"
        SERVICE_NAME_FABRIC_API = "fabric-api"
        SERVICE_NAME_FABRIC_NEO4J    = "fabric-neo4j"
        SERVICE_NAME_FABRIC_POSTGRES = "fabric-postgres"
        SERVICE_NAME_INIT_STATE = "init-state"
        SERVICE_NAME_SYNC_WORKER = "sync-worker"
        HOST                    = "0.0.0.0"
        FABRIC_IMAGE_TAG        = "p5-master"
        SOURCE_COMMIT           = "35f97bbe1f3065198fa23ab516bb25ab6ba2e2a6"
        FABRIC_STORE_ROOT       = "/state"
        cache_root_directory    = "/state/cognee/cache"
        data_root_directory     = "/state/cognee/data"
        system_root_directory   = "/state/cognee/system"
        FABRIC_COGNEE_PYTHON    = "/opt/cognee-venv/bin/python"
        FABRIC_NEO4J_URL        = "bolt://fabric-neo4j:7687"
        FABRIC_LLM_MODEL        = "openai/auto/best-free"
        FABRIC_ALLOWED_REPOS    = "KSonny4/Graft,KSonny4/OmniRoute,KSonny4/OmniRouteSetup,KSonny4/automatization,KSonny4/context-fabric,KSonny4/control-panel,KSonny4/darknet-newsletter-code,KSonny4/engineering-guidance,KSonny4/graph-engineering,KSonny4/ideas,KSonny4/lidawake,KSonny4/llm-quota,KSonny4/mpcnc-skr-v1.4-turbo-setup,KSonny4/ovhcloud,KSonny4/pi-goal-list-loop-audit,KSonny4/pi-graft,KSonny4/pi-meta-oauth,KSonny4/polymarket-wallet-finder,KSonny4/psycare_web,KSonny4/python_template,KSonny4/release-radar,KSonny4/saas-template,KSonny4/secrets,KSonny4/sentinel,KSonny4/wedding-_scavenger_hunt"
        FABRIC_API_Bearer      = var.fabric_bearer
        GH_TOKEN               = var.gh_token
        GH_WEBHOOK_SECRET      = var.gh_webhook_secret
        OMNI_KEY               = var.omni_key
        NEO4J_PASSWORD         = var.neo4j_password
        POSTGRES_PASSWORD      = var.postgres_password
        R2_ACCESS_KEY_ID       = var.r2_access_key_id
        R2_SECRET_ACCESS_KEY   = var.r2_secret_access_key
        R2_ACCOUNT_ID          = var.r2_account_id
        R2_BUCKET              = var.r2_bucket
        R2_ENC_PASSPHRASE      = var.r2_enc_passphrase
        CF_ACCESS_CLIENT_ID    = var.cf_access_client_id
        CF_ACCESS_CLIENT_SECRET = var.cf_access_client_secret
        FABRIC_POSTGRES_URL    = "postgres://fabric:${var.postgres_password}@fabric-postgres:5432/fabric"
      }

      resources {
        cpu    = 500
        memory = 1024
      }

      service {
        name     = "fabric-api"
        port     = "http"
        provider = "nomad"

        check {
          type     = "http"
          path     = "/health"
          interval = "30s"
          timeout  = "5s"
        }

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.fabric.rule=Host(`fabric.pkubelka.cz`)",
          "traefik.http.routers.fabric.entrypoints=web",
        ]
      }
    }

    task "neo4j" {
      driver = "docker"

      config {
        image = "neo4j:5.26.0-community"
        ports = ["bolt", "http"]

        volumes = [
          "4voakknnfy2e2vah8xt9crnu_fabric-neo4j-data:/data",
          "4voakknnfy2e2vah8xt9crnu_fabric-neo4j-logs:/logs",
        ]
      }

      env {
        NEO4J_AUTH = "neo4j:${var.neo4j_password}"
      }

      resources {
        cpu    = 1000
        memory = 1536
      }

      service {
        name     = "fabric-neo4j"
        port     = "bolt"
        provider = "nomad"

        check {
          type     = "tcp"
          interval = "30s"
          timeout  = "5s"
        }
      }
    }

    task "postgres" {
      driver = "docker"

      config {
        image = "pgvector/pgvector:0.8.0-pg16"
        ports = ["db"]

        volumes = [
          "4voakknnfy2e2vah8xt9crnu_fabric-postgres-data:/var/lib/postgresql/data",
        ]
      }

      env {
        POSTGRES_USER     = "fabric"
        POSTGRES_DB       = "fabric"
        POSTGRES_PASSWORD = var.postgres_password
      }

      resources {
        cpu    = 250
        memory = 512
      }

      service {
        name     = "fabric-postgres"
        port     = "db"
        provider = "nomad"

        check {
          type     = "tcp"
          interval = "30s"
          timeout  = "5s"
        }
      }
    }

    network {
      port "http" {
        to           = 8080
        host_network = "loopback"
      }
      port "bolt" {
        to           = 7687
        host_network = "loopback"
      }
      port "db" {
        to           = 5432
        host_network = "loopback"
      }
    }
  }
}
