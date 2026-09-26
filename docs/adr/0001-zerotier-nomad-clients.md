# Home Nomad clients join over ZeroTier

The OVH host joins the existing ZeroTier network, and Nomad RPC (4647) and
serf (4648) bind to the ZeroTier interface only. Nothing is exposed publicly;
gossip stays encrypted; mTLS comes later.

## Considered Options

- **Public bind with firewall rules**: bind RPC/serf to the public interface
  and filter by source IP. Rejected: it puts cluster membership one firewall
  mistake away from the open internet, and home IPs (Pi behind Mullvad,
  Fujitsu on a residential LAN) are not stable allowlist entries.
- **Tailscale instead of ZeroTier**: the Pi already has a Tailscale IP and
  Fujitsu is reachable over ZeroTier today. Rejected: both home hosts and the
  operator tooling (polymarket SSH paths, HUGO control traffic) already run
  on the existing ZeroTier network, so a second mesh adds identity and
  routing state for no gain.
- **mTLS now**: full `tls {}` stanza on server and clients from day one.
  Rejected (deferred, not dropped): gossip encryption plus a ZeroTier-only
  bind is enough to join safely; mTLS lands as a follow-up reship once both
  clients are `ready`, so a certificate mistake cannot block the first join.

## Consequences

- The OVH server agent keeps its loopback bind until Slice P step 3 [YES],
  when it is reshipped to bind RPC/serf to its new ZeroTier address with the
  same pre-shared gossip key the clients ship at provision time. Running
  allocations survive the agent restart.
- Clients (`config/clients/pi.hcl`, `config/clients/fujitsu.hcl`) set
  `bind_addr` and every `advertise` endpoint to their ZeroTier IP, join via
  `server_join.retry_join` pointing at the OVH ZeroTier IP from
  `config/clients/inventory.json`, and live in `datacenter = "ovh-vps"` with
  `node_pool = "home"` — so the default pool stays OVH-only with no per-job
  constraint needed yet, and pool `home` becomes the Slice 4 sandbox pool.
- Docker bind mounts stay off on both clients (`volumes { enabled = false }`):
  any submit-job token is effectively root while host-path mounts are on, and
  these clients will run sandbox work. The server keeps volumes on for the
  registry htpasswd mount (see `config/nomad.hcl`); that exception is
  single-tenant and ACL-gated.
- Pi routing: all Pi traffic is policy-routed into the Mullvad WireGuard
  tunnel, so ZeroTier member traffic must bypass the VPN with the same
  mechanism the cloudflared guard already uses
  (`automatization/scripts/cloudflared-tunnel-guard.sh`): a destination
  `ip rule` at fixed priority 1 — `ip -4 rule add pref 1 to
  <zerotier-prefix> lookup main` — ahead of wg-quick's variable-priority
  kill-switch rules, never an iptables fwmark (an OUTPUT mangle mark lands
  after the socket has picked the VPN source address, so replies never
  return). The exact managed-route CIDR is a `TODO(owner)` in the inventory
  until the OVH host joins and the prefix is confirmed.
- Fujitsu keeps ~8 GB reserved for its existing recorder set while it doubles
  as a client; the Pi keeps 2 GB for its systemd/Docker services. Both
  reservations are data in the inventory, revisited after Slice N telemetry.
