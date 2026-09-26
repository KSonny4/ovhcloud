# Nomad agent telemetry scraper (Slice N step 2, Refs KSonny4/platform#16).
#
# Scrapes the local Nomad agent's Prometheus endpoint
# (http://127.0.0.1:4646/v1/metrics?format=prometheus, enabled by the
# `telemetry` block in config/nomad.hcl) and remote-writes the series to
# Grafana Cloud. Gives the second Slice N right-size pass real usage
# history instead of point samples.
#
# Pattern: matches the existing Alloy jobs — image + remote_write shape from
# the dump Alloy task (feat/dump-grafana-alloy) and the live keeper-alloy /
# cognee-alloy jobs (host network, task-relative `local/config.alloy`,
# password via sys.env + task env, never baked into Git).
#
# ACL: none needed for the scrape. The /v1/metrics endpoint requires no ACL
# (Nomad HTTP API docs: "ACL Required: none"), verified live 2026-09-26 —
# an unauthenticated GET reached the endpoint (it answered 415 "Prometheus
# is not enabled" because the telemetry block was not yet applied, not
# 403). So no Nomad token is wired into this job.
#
# pg-shared (KSonny4/nomad-postgresql#1): also scrapes the shared
# PostgreSQL 18 postgres_exporter at 127.0.0.1:9187 (the pg-shared job's
# `metrics` port, host_network loopback, static). Series carry
# job="pg-shared"; the Grafana alert rules in grafana/alerts/pg-shared.json
# select on that label. Static target on purpose: this job holds no Nomad
# token, so Nomad service discovery is not used. The exporter connects as
# the pg_monitor role `monitor` and needs no credential here.
#
# Credentials: Grafana Cloud write token arrives as an HCL2 var at the
# deploy edge (values from Bao, memory-only, never committed):
#   nomad job run \
#     -var="grafana_cloud_rw2_token=$(bao kv get -field=token secret/projects/nomad/GRAFANA_CLOUD_RW2)" \
#     jobs/nomad-metrics-alloy.nomad.hcl
# Roll back: nomad job stop nomad-metrics-alloy (shipping stops; history
# already in Cloud stays queryable).
variable "grafana_cloud_rw2_token" {
  type        = string
  default     = ""
  description = "Grafana Cloud metrics write token (Bao secret/projects/nomad/GRAFANA_CLOUD_RW2 field token). Empty fails loud at remote_write auth."
}

job "nomad-metrics-alloy" {
  datacenters = ["ovh-vps"]
  type        = "service"

  group "alloy" {
    count = 1

    # HOST network (measured 2026-09-19): the client has NO CNI plugins,
    # so bridge groups never place. The scrape target is the host loopback
    # agent (127.0.0.1:4646), reachable only from host network mode.
    network {
      port "alloy" {
        host_network = "loopback"
      }
    }

    task "alloy" {
      driver = "docker"

      config {
        network_mode = "host"
        image        = "grafana/alloy:v1.19.2@sha256:b8ec653c44235fbe910879145dac3597d66b0aaecf60bcbbe82580767771a839"
        ports        = ["alloy"]
        args = [
          "run",
          "--storage.path=/alloc/data",
          "--server.http.listen-addr=127.0.0.1:${NOMAD_PORT_alloy}",
          "/local/config.alloy",
        ]
      }

      env {
        GRAFANA_CLOUD_RW2_TOKEN = var.grafana_cloud_rw2_token
      }

      template {
        destination = "local/config.alloy"
        change_mode = "restart"
        data        = <<-EOH
          prometheus.scrape "nomad" {
            targets = [
              {"__address__" = "127.0.0.1:4646"},
            ]
            forward_to      = [prometheus.remote_write.cloud.receiver]
            scrape_interval = "30s"
            metrics_path    = "/v1/metrics"
            params          = { "format" = ["prometheus"] }
          }

          prometheus.scrape "pg_shared" {
            targets = [
              {"__address__" = "127.0.0.1:9187", "service" = "pg-shared"},
            ]
            forward_to      = [prometheus.remote_write.cloud.receiver]
            job_name        = "pg-shared"
            scrape_interval = "30s"
          }

          prometheus.remote_write "cloud" {
            endpoint {
              url = "https://prometheus-prod-55-prod-gb-south-1.grafana.net/api/prom/push"

              basic_auth {
                username = "2961502"
                password = sys.env("GRAFANA_CLOUD_RW2_TOKEN")
              }
            }
          }
        EOH
      }

      resources {
        cpu        = 100
        memory     = 128
        memory_max = 256
      }
    }
  }
}
