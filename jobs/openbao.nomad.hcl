# OpenBao 2.6.2 on Nomad, using the existing Neon PostgreSQL storage.
# Do not run until the Pi node is also configured for PostgreSQL HA and
# direct, restricted cluster traffic between both hosts has been proven.

variable "cluster_address" {
  type        = string
  default     = ""
  description = "Private interface address bound and advertised for OpenBao cluster traffic (TCP 8201)."

  validation {
    condition     = var.cluster_address != ""
    error_message = "Set cluster_address to the private Nomad host interface address."
  }
}

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

      port "cluster" {
        static       = 8201
        host_network = "openbao-cluster"
      }
    }

    task "server" {
      driver = "docker"

      config {
        image        = "openbao/openbao:2.6.2"
        network_mode = "host"
        ports        = ["api", "cluster"]
        volumes      = ["local/openbao.hcl:/openbao/config.hcl:ro"]
        args          = ["server", "-config=/openbao/config.hcl"]
      }

      env {
        BAO_ADDR = "http://127.0.0.1:8200"
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
        change_mode = "restart"
        data = <<-EOT
          storage "postgresql" {
            table      = "openbao_kv_store"
            ha_enabled = true
            ha_table   = "openbao_ha_locks"
          }

          listener "tcp" {
            address         = "127.0.0.1:8200"
            cluster_address = "${var.cluster_address}:8201"
            tls_disable     = true
          }

          api_addr      = "https://secrets.pkubelka.cz"
          cluster_addr  = "https://${var.cluster_address}:8201"
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
