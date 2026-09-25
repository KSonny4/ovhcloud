# Single-instance OpenBao 2.6.2 on Nomad, using the existing Neon database.
# Stop the Pi instance before starting this job: both processes must not write
# to the same storage at the same time. Roll back by stopping this job first.

job "openbao" {
  datacenters = ["ovh-vps"]
  type        = "service"

  group "openbao" {
    count = 1

    network {
      mode = "host"

      port "api" {
        static       = 8200
        host_network = "loopback"
      }
    }

    task "server" {
      driver = "docker"

      config {
        image        = "openbao/openbao:2.6.2"
        network_mode = "host"
        ports        = ["api"]
        volumes      = ["local/openbao.hcl:/openbao/config.hcl:ro"]
        args          = ["server", "-config=/openbao/config.hcl"]
      }

      env {
        BAO_ADDR = "http://127.0.0.1:8200"
      }

      identity {
        env = true
      }

      template {
        destination = "secrets/postgresql.env"
        perms       = "0600"
        env         = true
        change_mode = "restart"
        data = <<-EOT
          BAO_PG_CONNECTION_URL={{ with nomadVar "nomad/jobs/openbao/openbao/server" }}{{ .connection_url | toJSON }}{{ end }}
        EOT
      }

      template {
        destination = "local/openbao.hcl"
        perms       = "0600"
        uid         = 100
        gid         = 1000
        change_mode = "restart"
        data = <<-EOT
          storage "postgresql" {
            table = "openbao_kv_store"
          }

          listener "tcp" {
            address     = "127.0.0.1:8200"
            tls_disable = true
          }

          api_addr      = "https://secrets.pkubelka.cz"
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

        check {
          type     = "tcp"
          interval = "10s"
          timeout  = "3s"
        }
      }
    }
  }
}
