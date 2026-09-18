# 01. Prepare the OVH VPS

The automated path provisions a fresh host with one command (see
[00. Quickstart](00-quickstart.md)). This page covers what the automation
needs from you up front, plus the provider-side facts no API can supply.

## 1. Automated path (primary)

```bash
# 1. Mint the provisioning keypair (escrowed in OpenBao, never in Git):
bash scripts/run-remote-provision.sh --generate-key-only
# 2. Order/install the VPS (Ubuntu 24.04 or 26.04) with that public key
#    injected at install time (OVH account keys apply at install only).
# 3. Run the full provisioner:
PROVISION_HOST=<vps-hostname> PROVISION_ZONE=<zone> \
  bash scripts/run-remote-provision.sh
```

The runner refuses preserved targets, verifies Docker, installs Nomad,
wires Tunnel/DNS/Access, schedules backups, and adopts everything into
Terraform with a zero-change plan assertion. Nothing below needs to be
done by hand on a fresh host.

## 2. Record recovery information first

In OVHcloud Control Panel (`Bare Metal Cloud -> Virtual private servers`):

- VPS service name, public IPv4/IPv6, datacentre/region, plan, installed OS.

Store these privately, **not in this repository**. Also locate the **KVM
console** and **rescue mode** before changing anything — they are the
recovery path if access breaks (see break-glass appendix).

## 3. Provider firewall notes (informational)

OVH Anti-DDoS applies automatically. The optional Edge Network Firewall is
stateless, IPv4-only, max 20 rules per IP. Steady state for this platform:

- public Internet: only what Cloudflare needs (nothing, when fully tunnelled);
- administration: Cloudflare Tunnel + Access, never public SSH;
- emergency: OVH KVM/rescue mode.

Do not build a deny-all Edge rule before Tunnel + Access and a tested
recovery route work.

## Done when

- [x] VPS ordered with the provisioning public key injected
- [x] provisioner completes (Docker verified, Nomad live, edge wired)
- [x] KVM/rescue path is known
- [x] no secrets were committed to Git

Next: [00. Quickstart](00-quickstart.md) (the provisioner covers 02–05).

## Appendix: break-glass (automation unavailable)

First connection only (key injected at install; password login is a
last resort via KVM):

```bash
ssh -i ~/.ssh/ovh_nomad_ed25519 ubuntu@<VPS_IPV4>
cat /etc/os-release && nproc && free -h && lsblk
```

Handy workstation alias (`~/.ssh/config`):

```sshconfig
Host ovh-vps
    HostName <VPS_IPV4>
    User ubuntu
    IdentityFile ~/.ssh/ovh_nomad_ed25519
    IdentitiesOnly yes
```
