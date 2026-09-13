# 01. Prepare the OVH VPS

This starts from a newly purchased OVHcloud VPS with no trusted configuration on it yet.

## 1. Record recovery information first

In OVHcloud Control Panel:

`Bare Metal Cloud -> Virtual private servers -> <your VPS>`

Record somewhere private, **not in this repository**:

- VPS service name
- public IPv4 and IPv6
- datacentre/region
- current plan
- OS currently installed

Also locate the **KVM console** and OVH **rescue mode** before changing SSH or firewall settings. These are your recovery paths if you lock yourself out.

OVH's current VPS documentation makes you responsible for configuration, security, maintenance and backups.

## 2. Use Ubuntu 24.04 LTS

If the VPS is not already running Ubuntu 24.04 LTS, reinstall it now while it contains no data worth preserving.

Coolify supports Ubuntu LTS and its automated installation path explicitly supports Ubuntu 24.04.

After reinstall, OVH normally uses an OS-specific non-root account. For Ubuntu this is `ubuntu`. The delivery email/control panel tells you the exact username.

## 3. Create a dedicated SSH key on your Mac/workstation

Do not reuse a random old key and do not put the private key in this repository.

```bash
ssh-keygen -t ed25519 -a 100 \
  -f ~/.ssh/ovh_vps_ed25519 \
  -C "ovh-vps"
```

Use a passphrase for your human key.

Show the public key:

```bash
cat ~/.ssh/ovh_vps_ed25519.pub
```

If reinstalling from the OVH panel offers an SSH-key option, add this **public** key there. Otherwise add it after the first password login.

## 4. First connection

```bash
ssh ubuntu@<VPS_IPV4>
```

If the key is not selected automatically:

```bash
ssh -i ~/.ssh/ovh_vps_ed25519 ubuntu@<VPS_IPV4>
```

Then inspect the machine before changing anything:

```bash
cat /etc/os-release
uname -a
nproc
free -h
lsblk
df -hT
ip addr
ip route
```

Expected baseline is Ubuntu 24.04 LTS and the CPU/RAM/disk matching the plan you purchased.

## 5. Add a local SSH alias

On your workstation, add to `~/.ssh/config`:

```sshconfig
Host ovh-vps
    HostName <VPS_IPV4>
    User ubuntu
    IdentityFile ~/.ssh/ovh_vps_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 30
    ServerAliveCountMax 3
```

Then:

```bash
ssh ovh-vps
```

## 6. OVH network protection

OVH provides Anti-DDoS automatically. For a VPS public IP you can also configure the **Edge Network Firewall** from:

`Network -> Public IP Addresses -> <IPv4> -> Configure Edge Network Firewall`

Important facts from OVH's current documentation:

- it is **stateless**;
- it applies to IPv4;
- it can hold up to 20 rules per IP;
- it supplements rather than replaces the host firewall;
- configured rules can be activated automatically during DDoS mitigation, even if you normally leave the Edge firewall disabled.

For this Coolify host, the intended public application surface is eventually only TCP 80 and 443. SSH and Coolify bootstrap ports should be temporary/restricted.

Do **not** blindly build a deny-all Edge Network Firewall before you have Tailscale and a tested recovery route. A bad rule can lock out legitimate traffic during DDoS mitigation.

Official reference:

https://docs.ovhcloud.com/en/guides/bare-metal-cloud/dedicated-servers/firewall-network

## 7. Bootstrap exposure

During initial setup, allow only what you need:

- TCP 22 for SSH, ideally restricted to your current public IP if practical
- later TCP 80 and 443 for Coolify applications
- TCP 8000 only while claiming/configuring the first Coolify administrator if you use the direct-IP setup flow

Coolify also uses 6001/6002 with direct-IP dashboard access. Once the dashboard has an HTTPS domain through the Coolify proxy, public 8000/6001/6002 should be closed.

## 8. Recovery test

Before continuing, confirm you can locate:

- OVH KVM console
- rescue mode
- VPS reinstall action

Do not actually reinstall once real data exists without verified backups.

## Done when

- [ ] Ubuntu 24.04 LTS is installed
- [ ] dedicated ED25519 human SSH key exists
- [ ] `ssh ovh-vps` works
- [ ] VPS resources match the purchased plan
- [ ] KVM/rescue path is known
- [ ] no secrets were committed to Git

Next: [02. Bootstrap and secure Ubuntu](02-host-bootstrap.md)
