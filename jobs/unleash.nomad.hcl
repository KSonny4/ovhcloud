# Unleash feature flags on Nomad (restored 2026-09-19 after old-VPS
# decommission; specs were host-local on the expired VPS, reconstructed here).
#
# Shape: postgres (owns /opt/nomad-volumes/unleash-pg, PG16, single-writer)
# + server (Unleash, auto-migrates schema on boot). Data restored from the
# pre-termination migration archive (/srv/old-vps-migration on the host);
# role password was reset post-restore and escrowed (never in this file).
#
# Conventions follow jobs/cognee.nomad.hcl: network_mode "host" with
# EXPLICIT 127.0.0.1 binds (tunnel-only posture), scheduler-assigned
# dynamic loopback ports (NOMAD_PORT_*), TCP service checks, secrets as
# HCL2 vars at the deploy edge (values from Bao, never logged):
#   nomad job run -var="db_password=..." -var="init_client_token=..." jobs/unleash.nomad.hcl
# They live in Nomad's job store (ACL-gated). Public hostname
# unleash.pkubelka.cz is a tunnel ingress target (parent wires DNS/ingress).
#
# Deploy-edge host prerequisites:
#   /opt/nomad-volumes/unleash-pg (uid 999, restored PG16 cluster)

variable "db_password" {
  type        = string
  default     = ""
  description = "DATABASE_PASSWORD for role unleash (Bao secret/projects/unleash/env db_password). Empty fails the server task fast."
}

variable "init_client_token" {
  type        = string
  default     = ""
  description = "INIT_CLIENT_API_TOKENS seed (project:environment.secret). Empty boots without a seeded client token."
}

job "unleash" {
  datacenters = ["ovh-vps"]
  type        = "service"

  group "unleash" {
    count = 1

    network {
      port "db" {
        host_network = "loopback"
      }
      port "http" {
        host_network = "loopback"
      }
    }

    # Host-dir bootstrap: ensure the restored PG cluster exists and is
    # owned by the image postgres user (uid 999) before the db task starts.
    task "bootstrap" {
      driver = "docker"

      config {
        image = "postgres:16@sha256:a3b7f434b2dc57ce85a67e171163eb8ab1a1ebcb39d27484661f26b1dfbe30d6"
        volumes = [
          "/opt/nomad-volumes:/vol",
        ]
        args = [
          "sh", "-c",
          "mkdir -p /vol/unleash-pg && chown -R 999:999 /vol/unleash-pg && ls -ld /vol/unleash-pg",
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
        image = "postgres:16@sha256:a3b7f434b2dc57ce85a67e171163eb8ab1a1ebcb39d27484661f26b1dfbe30d6"
        ports = ["db"]
        volumes = [
          "/opt/nomad-volumes/unleash-pg:/var/lib/postgresql/data",
        ]
        # Existing cluster (PGDATA subdir, restored pre-deploy): the
        # entrypoint detects it and skips init. Loopback-only bind; the
        # port is scheduler-assigned (NOMAD_PORT_db).
        command = "postgres"
        args = [
          "-c", "listen_addresses=127.0.0.1",
          "-c", "port=${NOMAD_PORT_db}",
        ]
      }

      env {
        PGDATA = "/var/lib/postgresql/data/pgdata"
      }

      user = "root"

      resources {
        cpu    = 250
        memory = 512
      }

      service {
        name     = "unleash-postgres"
        port     = "db"
        provider = "nomad"

        check {
          type     = "tcp"
          interval = "15s"
          timeout  = "3s"
        }
      }
    }

    task "server" {
      driver = "docker"

      config {
        network_mode = "host"
        image = "unleashorg/unleash-server@sha256:5020013b7a9a93c8ed3686d36b5025399714020b3fb5ef41afd84ba37a88c050"
        ports = ["http"]
      }

      env {
        # Loopback-only bind (host netns): 0.0.0.0 here would sit on the
        # VPS public interface. Port is scheduler-assigned.
        HTTP_HOST = "127.0.0.1"
        HTTP_PORT = "${NOMAD_PORT_http}"
        DATABASE_HOST     = "127.0.0.1"
        DATABASE_PORT     = "${NOMAD_PORT_db}"
        DATABASE_NAME     = "unleash"
        DATABASE_USERNAME = "unleash"
        DATABASE_PASSWORD = "${var.db_password}"
        DATABASE_SSL      = "false"
        INIT_CLIENT_API_TOKENS = "${var.init_client_token}"
      }

      resources {
        cpu    = 500
        memory = 1024
      }

      service {
        name     = "unleash"
        port     = "http"
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
