# Nomad client agent config for the Raspberry Pi (pool `home`).
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
name       = "pi"
bind_addr  = "172.23.215.6"

advertise {
  http = "172.23.215.6:4646"
  rpc  = "172.23.215.6:4647"
  serf = "172.23.215.6:4648"
}

client {
  enabled    = true
  node_pool  = "home"
  node_class = "rpi"

  # OVH server over ZeroTier; mirrors inventory `server_join_ip`.
  # TODO(owner): OVH ZeroTier IP — the OVH host is not on the ZeroTier
  # network yet (Slice P step 3 [YES]); replace the placeholder in
  # inventory.json and reship.
  server_join {
    retry_join = ["TODO(owner): OVH ZeroTier IP"]
  }

  # Keep >= 2 GB for the Pi's existing systemd/Docker services (n8n,
  # streaming stack, Guacamole); Nomad schedules from the rest.
  reserved {
    memory = 2048
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
