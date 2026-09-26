# Single committed Nomad agent config (single server + client, loopback bind).
#
# Absorbed from NomadSetup `config/nomad.hcl` (Refs KSonny4/platform#15):
# this file keeps the dump host volumes and the Docker driver auth settings
# from that source. Installed on the target host by
# `scripts/provision-nomad.sh` (which ships this file alongside the script);
# never hand-edit `/etc/nomad.d/nomad.hcl` on the host.
#
# Secrets are NEVER committed here:
# - Gossip encryption ships in a separate protected file
#   (`/etc/nomad.d/gossip.hcl`, mode 0600) written at provision time from
#   the `NOMAD_GOSSIP_KEY` environment value (generated + escrowed
#   runner-side by `scripts/run-remote-provision.sh`), before the first
#   agent start. The server must boot encrypted from the beginning.
# - The Docker auth file (`/opt/nomad/docker-auth.json`, dockercfg format,
#   root-only) is written at the deploy edge from Bao and is only
#   *referenced* below, never inlined.
datacenter = "ovh-vps"
data_dir   = "/opt/nomad"
bind_addr  = "127.0.0.1"

# REQUIRED on Nomad 2.x with a loopback bind: it refuses to default-advertise
# localhost ("Defaulting advertise to localhost is unsafe"). Single node, so
# loopback advertise is correct — all consumers (tunnel, local CLI) use loopback.
advertise {
  http = "127.0.0.1:4646"
  rpc  = "127.0.0.1:4647"
  serf = "127.0.0.1:4648"
}

server {
  enabled          = true
  bootstrap_expect = 1
}

client {
  enabled = true
  servers = ["127.0.0.1:4647"]

  host_network "loopback" {
    interface = "lo"
  }

  # Backs the registry job's `volume "data"` (type = host). Added Task 10:
  # host volumes require a client-side declaration; path created by
  # scripts/provision-nomad.sh. Reshipping this config requires an agent
  # restart (safe: no jobs scheduled yet at introduction time).
  host_volume "registry-data" {
    path      = "/opt/nomad-volumes/registry"
    read_only = false
  }

  # dump app + postgres (KSonny4/dump#3): one host volume per environment.
  # pg dirs must be writable by uid 999 (postgres image user) — created at
  # deploy edge with `chown 999:999`. Reshipping needs an agent restart;
  # the registry job bounces (seconds, acceptable: no dump traffic yet).
  host_volume "dump-dev-media" {
    path      = "/opt/nomad-volumes/dump-dev-media"
    read_only = false
  }
  host_volume "dump-prod-media" {
    path      = "/opt/nomad-volumes/dump-prod-media"
    read_only = false
  }
  host_volume "dump-pg-dev" {
    path      = "/opt/nomad-volumes/dump-pg-dev"
    read_only = false
  }
  host_volume "dump-pg-prod" {
    path      = "/opt/nomad-volumes/dump-pg-prod"
    read_only = false
  }

  # Shared PostgreSQL 18 `pg-shared` (KSonny4/nomad-postgresql#1): PGDATA +
  # pgBackRest WAL spool. Owned 999:999 (postgres image user), mode 0700 —
  # created by scripts/provision-nomad.sh. Path is fixed by the
  # nomad-postgresql runbooks. Reshipping needs an agent restart.
  host_volume "pg-shared" {
    path      = "/opt/nomad/volumes/pg-shared"
    read_only = false
  }
}

acl {
  enabled = true
}

# Agent telemetry for Slice N right-sizing (Refs KSonny4/platform#16):
# exposes Prometheus-format metrics at /v1/metrics?format=prometheus for
# the nomad-metrics-alloy job to scrape. Reshipping this config requires
# an agent restart (running allocations survive it); see docs/03-nomad.md.
telemetry {
  collection_interval        = "10s"
  disable_hostname           = true
  prometheus_metrics         = true
  publish_allocation_metrics = true
  publish_node_metrics       = true
}

plugin "docker" {
  config {
    # Client-level registry auth (KSonny4/polymarket-wallet-finder#2438):
    # auths file written at the deploy edge from Bao
    # secret/projects/nomad/REGISTRY (fields username/password).
    # Jobspecs must not carry task-level auth blocks (they override this).
    # Pre-pull + force_pull=false is NOT sufficient alone: Nomad's own
    # image GC (default image=true, 3m delay) eats unused pre-pulled images.
    auth {
      config = "/opt/nomad/docker-auth.json"
    }

    allow_privileged = false

    # REQUIRED for the registry job's htpasswd bind-mount (Task 10 field
    # hit: driver refuses host-path mounts unless enabled). Single-tenant
    # box, job submission is ACL-gated — acceptable.
    volumes {
      enabled = true
    }
  }
}
