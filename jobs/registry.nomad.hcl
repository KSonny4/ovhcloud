# Private Docker registry on Nomad.
#
# Mirrors the proven live deployment (image pinned by digest 2026-09-17;
# host volume registry-data declared client-side by provision-nomad.sh).
# The htpasswd file content is rendered from OpenBao escrow
# (secret/projects/ovhcloud/REGISTRY) at deploy time into
# /opt/nomad-volumes/registry-auth/htpasswd on the client host —
# memory-only handling, never committed (see docs/09-docker-registry.md).
#
# Deploy: nomad job run jobs/registry.nomad.hcl
# Roll back: nomad job revert registry
job "registry" {
  datacenters = ["ovh-vps"]
  type        = "service"

  group "registry" {
    count = 1

    volume "data" {
      type      = "host"
      source    = "registry-data"
      read_only = false
    }

    task "registry" {
      driver = "docker"

      shutdown_delay = "5s"
      kill_timeout   = "40s"

      config {
        image = "registry:2.8.3@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373"
        ports = ["http"]

        volumes = [
          "/opt/nomad-volumes/registry-auth/htpasswd:/auth/htpasswd:ro",
        ]
      }

      volume_mount {
        volume      = "data"
        destination = "/var/lib/registry"
      }

      env {
        REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY = "/var/lib/registry"
        REGISTRY_AUTH                             = "htpasswd"
        REGISTRY_AUTH_HTPASSWD_REALM              = "Registry Realm"
        REGISTRY_AUTH_HTPASSWD_PATH               = "/auth/htpasswd"
        # REQUIRED behind the TLS-terminating tunnel: without this the
        # registry mints http:// upload URLs and every push fails on
        # resume (live failure 2026-09-17).
        REGISTRY_HTTP_HOST = "https://registry.pkubelka.cz"
        REGISTRY_STORAGE_DELETE_ENABLED = true
      }

      resources {
        cpu    = 250
        memory = 256
      }

      service {
        name     = "registry"
        port     = "http"
        provider = "nomad"

        # TCP liveness check (NOT http): with htpasswd on, /v2/ answers
        # 401 to anonymous requests and a 2xx-only http check would fail
        # forever. Auth enforcement is proven by the push/pull smoke
        # (anon 401) rather than the scheduler check — no credentials
        # belong in this spec.
        check {
          type     = "tcp"
          interval = "15s"
          timeout  = "3s"
        }

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.registry.rule=Host(`registry.pkubelka.cz`)",
          "traefik.http.routers.registry.entrypoints=web",
        ]
      }
    }

    network {
      port "http" {
        static       = 5000
        host_network = "loopback"
      }
    }
  }
}
