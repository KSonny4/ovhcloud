# Mirror of KSonny4/secrets-local jobs/openbao.nomad.hcl; maintain canonical setup there.
# Two OpenBao processes on the existing Nomad host; Neon provides HA locking.
# Stop the standalone Pi instance before unsealing either Nomad allocation.
# Both allocations must be manually unsealed after startup.

job "openbao" {
  datacenters = ["ovh-vps"]
  type        = "service"

  group "openbao" {
    count = 2

    update {
      max_parallel      = 1
      min_healthy_time  = "10s"
      healthy_deadline  = "30m"
      progress_deadline = "35m"
    }

    network {
      mode = "host"

      port "api" {
        host_network = "loopback"
      }

      port "cluster" {
        host_network = "loopback"
      }
    }

    task "server" {
      driver         = "docker"
      shutdown_delay = "5s"

      config {
        image        = "openbao/openbao:2.6.2@sha256:11fd73a2102cda9c55d5d881a8c3210303146a7ec1e8ac76f526e175c6d24641"
        network_mode = "host"
        ports        = ["api", "cluster"]
        volumes      = ["local/openbao.hcl:/openbao/config.hcl:ro", "/srv/openbao/audit/${NOMAD_ALLOC_INDEX}:/openbao/audit"]
        args         = ["server", "-config=/openbao/config.hcl"]
      }

      env {
        BAO_ADDR = "http://${NOMAD_ADDR_api}"
      }

      identity {
        env = true
      }

      template {
        destination = "secrets/postgresql.env"
        perms       = "0600"
        env         = true
        change_mode = "restart"
        data        = <<-EOT
          BAO_PG_CONNECTION_URL={{ with nomadVar "nomad/jobs/openbao/openbao/server" }}{{ .connection_url | toJSON }}{{ end }}
        EOT
      }

      template {
        destination = "local/openbao.hcl"
        perms       = "0600"
        uid         = 100
        gid         = 1000
        change_mode = "restart"
        data        = <<-EOT
          storage "postgresql" {
            ha_enabled          = "true"
            skip_create_table   = "false"
            max_connect_retries = 0
          }

          listener "tcp" {
            address     = "{{ env "NOMAD_ADDR_api" }}"
            cluster_address = "{{ env "NOMAD_ADDR_cluster" }}"
            tls_disable = true
            disable_unauthed_rekey_endpoints = true
          }

          audit "file" "local" {
            description = "Local OpenBao audit trail"
            options {
              file_path = "/openbao/audit/audit.log"
              mode      = "0600"
            }
          }

          api_addr      = "https://secrets.pkubelka.cz"
          cluster_addr  = "https://{{ env "NOMAD_ADDR_cluster" }}"
          disable_mlock = true
          ui            = true
        EOT
      }

      resources {
        cpu    = 500
        memory = 512
      }

      service {
        name     = "openbao"
        port     = "api"
        provider = "nomad"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.openbao.rule=Host(`secrets.pkubelka.cz`)",
          "traefik.http.routers.openbao.entrypoints=web",
          "traefik.http.routers.openbao.service=openbao",
          "traefik.http.services.openbao.loadbalancer.healthcheck.path=/v1/sys/health",
          "traefik.http.services.openbao.loadbalancer.healthcheck.interval=2s",
          "traefik.http.services.openbao.loadbalancer.healthcheck.timeout=1s",
        ]

        check {
          type     = "http"
          path     = "/v1/sys/health?standbyok=true"
          interval = "5s"
          timeout  = "2s"
        }
      }
    }
  }
}
