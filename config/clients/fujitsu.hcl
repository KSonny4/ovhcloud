# Nomad client agent config for Fujitsu (pool `home`).
#
# Refs KSonny4/platform#27 (Slice P, repo part): values that can change
# (IPs, arch, pool, class, reservations) are data in
# config/clients/inventory.json — this file mirrors them, and
# tests/test_nomad_clients.py fails if they drift apart. Installed on the
# host by scripts/provision-client.sh as /etc/nomad.d/client.hcl; never
# hand-edit the host copy.
#
# Network (docs/adr/0001-zerotier-nomad-clients.md): the agent binds RPC
# 4647 and serf 4648 to the ZeroTier interface only. Nothing is public.
# Gossip encryption ships in /etc/nomad.d/gossip.hcl (0600) at provision
# time, like the server; mTLS comes later.
datacenter = "ovh-vps"
data_dir   = "/opt/nomad"
name       = "fujitsu"
bind_addr  = "172.23.229.176"

advertise {
  http = "172.23.229.176:4646"
  rpc  = "172.23.229.176:4647"
  serf = "172.23.229.176:4648"
}

client {
  enabled    = true
  node_pool  = "home"
  node_class = "fujitsu"

  # OVH server over ZeroTier; mirrors inventory `server_join_ip`.
  # OVH host ovh-nomad-fresh joined ZeroTier on 2026-09-26 (owner manual
  # join + Central authorize); this address is its member IP.
  server_join {
    retry_join = ["172.23.6.223"]
  }

  # 8 GB stays with the existing recorder set (~4.9 GB) + system headroom
  # on this 15 GB box; Nomad schedules history-heavy / non-critical jobs
  # from the rest. Revisit after Slice N telemetry.
  reserved {
    memory = 8192
  }
}

plugin "docker" {
  config {
    allow_privileged = false

    # No host-path mounts on home-pool clients: any submit-job token is
    # effectively root while bind mounts are on, so clients that will run
    # sandbox work keep them off. (The server keeps volumes on for the
    # registry htpasswd mount; see config/nomad.hcl.)
    volumes {
      enabled = false
    }
  }
}
