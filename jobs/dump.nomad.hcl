# Dump stack on Nomad — restored 2026-09-19 from the decommissioned old VPS.
#
# Shape: postgres (owns /opt/nomad-volumes/dump-pg-prod, PG 17, single-writer)
# + app (node dist/server/server.mjs on the tunnel's loopback port, media at
# /opt/nomad-volumes/dump-prod-media). Image rescued from the old registry
# blobs and re-pushed as registry.pkubelka.cz/dump:restored-20260919.
# Conventions follow jobs/cognee.nomad.hcl: host network_mode, loopback
# ports, TCP checks, no public listeners.
#
# Secrets arrive as HCL2 vars at the deploy edge (values from Bao):
#   nomad job run -var="db_password=..." jobs/dump.nomad.hcl
# DB password escrowed at secret/projects/dump/env db_password (fresh,
# generated at restore; old password unknown). Empty password fails LOUD at
# PG auth (fail-closed, no silent misconfig).
#
# KNOWN GAP: CLERK_PUBLISHABLE_KEY / CLERK_SECRET_KEY are user-held (Clerk
# dashboard) and were NOT recoverable from the old host. The app boots
# without them; auth-gated routes fail until they are provided. Do not
# invent values — wire them via -var when the operator supplies them.
variable "db_password" {
  type        = string
  default     = ""
  description = "Postgres role 'dump' password (Bao secret/projects/dump/env db_password). Empty fails loud at PG auth."
}

variable "clerk_publishable_key" {
  type        = string
  default     = ""
  description = "Clerk publishable key (user-held). Empty boots without auth."
}

variable "clerk_secret_key" {
  type        = string
  default     = ""
  description = "Clerk secret key (user-held). Empty boots without auth."
}

variable "registry_user" {
  type        = string
  default     = ""
  description = "Registry basic-auth username (Bao secret/projects/nomad/REGISTRY username) for the docker pull."
}

variable "registry_password" {
  type        = string
  default     = ""
  description = "Registry basic-auth password (Bao secret/projects/nomad/REGISTRY password). Same trust boundary as the ACL token."
}

job "dump" {
  datacenters = ["ovh-vps"]
  type        = "service"

  group "dump" {
    count = 1

    # HOST network_mode (measured 2026-09-19): the client has NO CNI
    # plugins, so bridge groups never place (eval blocked forever).
    # The bundle has no bind-address knob (0.0.0.0), but posture holds:
    # DOCKER-USER drops external packets to task ports (verified: outside
    # curl times out, exit 28) and the live gate watches the DROP counter.
    network {
      port "db" {
        host_network = "loopback"
      }
      port "app" {
        host_network = "loopback"
        # Cloudflare's dump ingress uses this fixed loopback origin port.
        static       = 30692
      }
    }

    task "bootstrap" {
      driver = "docker"

      config {
        image = "postgres:17"
        volumes = [
          "/opt/nomad-volumes:/vol",
        ]
        args = [
          "sh", "-c",
          "mkdir -p /vol/dump-pg-prod /vol/dump-prod-media && chown -R 999:999 /vol/dump-pg-prod && ls -ld /vol/dump-pg-prod /vol/dump-prod-media",
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

    task "postgres" {
      driver = "docker"

      config {
        network_mode = "host"
        image = "postgres:17"
        ports = ["db"]
        # Extra postgres argv (entrypoint still runs): loopback-only,
        # scheduler-assigned port. PGDATA points at the pgdata SUBDIR —
        # without it the entrypoint sees an "uninitialized" data dir and
        # refuses to boot (field hit 2026-09-19).
        args = [
          "-c", "listen_addresses=127.0.0.1",
          "-c", "port=${NOMAD_PORT_db}",
        ]
        volumes = [
          "/opt/nomad-volumes/dump-pg-prod:/var/lib/postgresql/data",
        ]
      }

      env {
        PGDATA = "/var/lib/postgresql/data/pgdata"
        POSTGRES_HOST_AUTH_METHOD = "scram-sha-256"
      }

      resources {
        cpu    = 500
        memory = 512
      }

      service {
        name     = "dump-postgres"
        port     = "db"
        provider = "nomad"

        check {
          type     = "tcp"
          interval = "15s"
          timeout  = "3s"
        }
      }
    }

    task "app" {
      driver = "docker"

      config {
        network_mode = "host"
        image = "registry.pkubelka.cz/dump:e8e6b06@sha256:a1ed38d1b858a9309915d13bccf17e7d825d8798112d1be419b4984dd73faff6"
        ports = ["app"]
        # Nomad runs as root (no docker config): pull creds via vars.
        auth {
          username = var.registry_user
          password = var.registry_password
        }
        volumes = [
          "/opt/nomad-volumes/dump-prod-media:/data/media",
        ]
      }

      # HCL interpolation (proven cognee pattern): job vars + NOMAD_PORT_*
      # both resolve here. No template stanza: Nomad templates cannot read
      # HCL2 vars, and secrets must not transit extra files anyway.
      env {
        PORT            = "${NOMAD_PORT_app}"
        PUBLIC_ORIGIN   = "https://dump.petrzdena.cz"
        DATABASE_URL    = "postgres://dump:${var.db_password}@127.0.0.1:${NOMAD_PORT_db}/dump"
        DB              = "postgres://dump:${var.db_password}@127.0.0.1:${NOMAD_PORT_db}/dump"
        DB_APPLY_SCHEMA = "true"
        MEDIA           = "/data/media"
        MEDIA_DIR       = "/data/media"
        CLERK_PUBLISHABLE_KEY = "${var.clerk_publishable_key}"
        CLERK_SECRET_KEY      = "${var.clerk_secret_key}"
      }

      # Ride out postgres boot + first-run migrations: the app has no
      # wait-for-db, so early attempts ECONNREFUSED and must retry.
      restart {
        attempts = 5
        delay    = "15s"
        interval = "10m"
        mode     = "delay"
      }

      resources {
        cpu    = 500
        memory = 512
      }

      service {
        name     = "dump"
        port     = "app"
        provider = "nomad"

        check {
          type     = "tcp"
          interval = "15s"
          timeout  = "3s"
        }
      }
    }
  }
}
