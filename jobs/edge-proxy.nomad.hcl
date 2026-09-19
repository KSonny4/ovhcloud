# Edge reverse proxy (single instance, Host-based routing to :80).
#
# All tunneled application hostnames (registry)
# terminate at the Cloudflare edge and arrive at localhost:80, where this
# job routes by Host to the backing Nomad services. Replaces the retired
# plane's per-app proxy wiring with one declarative job.
#
# Deploy: nomad job run jobs/edge-proxy.nomad.hcl
# Roll back: nomad job revert edge-proxy
job "edge-proxy" {
  datacenters = ["ovh-vps"]
  type        = "service"

  group "proxy" {
    count = 1

    task "traefik" {
      driver = "docker"

      shutdown_delay = "5s"

      config {
        image = "traefik:v3.7"
        ports = ["web"]
        args = [
          "--entrypoints.web.address=:80",
          "--providers.nomad=true",
          "--providers.nomad.endpoint.address=http://127.0.0.1:4646",
          "--providers.nomad.exposedbydefault=false",
          "--api=false",
          "--ping=true",
        ]
      }

      resources {
        cpu    = 200
        memory = 128
      }

      service {
        name     = "edge-proxy"
        port     = "web"
        provider = "nomad"

        check {
          type     = "http"
          path     = "/ping"
          interval = "15s"
          timeout  = "3s"
        }
      }
    }

    network {
      port "web" {
        static       = 80
        host_network = "loopback"
      }
    }
  }
}
