# 02. Bootstrap and secure Ubuntu

Run this before installing Coolify.

> Keep your current SSH session open while changing SSH settings. Test every access change from a second terminal before closing the first session.

## 1. Update the machine

```bash
sudo apt update
sudo DEBIAN_FRONTEND=noninteractive apt full-upgrade -y
sudo apt install -y \
  ca-certificates curl git jq vim htop tmux \
  openssh-server unattended-upgrades
```

Check whether a reboot is required:

```bash
if [ -f /var/run/reboot-required ]; then
  cat /var/run/reboot-required
fi
```

If required:

```bash
sudo reboot
```

Reconnect and verify:

```bash
uptime
uname -a
```

## 2. Hostname and time

Use a boring stable hostname. Example:

```bash
sudo hostnamectl set-hostname ovh-app-1
hostnamectl
```

Keep the server on UTC unless an application has a strong reason otherwise:

```bash
sudo timedatectl set-timezone UTC
timedatectl
```

Applications can use their own timezone.

## 3. Prepare root key access for Coolify

Coolify manages servers over SSH, including the `localhost` server on which self-hosted Coolify itself runs. Its current guidance recommends key-based root SSH with password login disabled.

Copy the already-tested human public key to root:

```bash
sudo install -d -m 700 /root/.ssh
sudo touch /root/.ssh/authorized_keys
sudo chmod 600 /root/.ssh/authorized_keys
cat ~/.ssh/authorized_keys | sudo tee -a /root/.ssh/authorized_keys >/dev/null
sudo sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys
```

Test from a **second local terminal** before changing SSH policy:

```bash
ssh -i ~/.ssh/ovh_vps_ed25519 root@<VPS_IPV4>
```

Do not continue until root key login works.

## 4. Harden OpenSSH without breaking Coolify

Create a drop-in rather than rewriting the vendor file:

```bash
sudo tee /etc/ssh/sshd_config.d/99-ovh-hardening.conf >/dev/null <<'EOF'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin prohibit-password
X11Forwarding no
MaxAuthTries 3
EOF
```

Validate before restart:

```bash
sudo sshd -t
```

No output means the syntax is valid. Then:

```bash
sudo systemctl restart ssh
sudo systemctl status ssh --no-pager
```

Again test both of these from a second terminal:

```bash
ssh -i ~/.ssh/ovh_vps_ed25519 ubuntu@<VPS_IPV4>
ssh -i ~/.ssh/ovh_vps_ed25519 root@<VPS_IPV4>
```

`PermitRootLogin prohibit-password` is intentional. Coolify's self-hosted localhost connection expects SSH and the official setup supports this mode.

## 5. Install Cloudflare Tunnel for administration

Cloudflare Tunnel becomes the normal human-administration path. `cloudflared` establishes outbound-only connections from the VPS, so SSH does not need a public inbound port after the tunnel is proven.

In Cloudflare:

1. go to `Networking -> Tunnels`;
2. create a Cloudflare Tunnel for this VPS;
3. choose the Linux connector instructions;
4. run the generated install command on the VPS;
5. verify the connector shows **Healthy**.

The dashboard-generated command normally installs `cloudflared` as a service with a tunnel token. Treat that token as a secret and never commit it.

Verify locally:

```bash
systemctl status cloudflared --no-pager
journalctl -u cloudflared -n 50 --no-pager
```

## 6. Publish SSH through Cloudflare and protect it with Access

On the tunnel, add a published application route:

```text
Hostname: ssh.example.com
Service:  SSH
Target:   localhost:22
```

Then create a Cloudflare Access self-hosted application for `ssh.example.com` and restrict it to your chosen identity/account. Do not leave the SSH hostname without an Access policy.

On your Mac/workstation, install `cloudflared`. With Homebrew:

```bash
brew install cloudflared
command -v cloudflared
```

Add an SSH config entry using the actual path printed by `command -v cloudflared`:

```sshconfig
Host ovh-cloudflare
    HostName ssh.example.com
    User root
    IdentityFile ~/.ssh/ovh_vps_ed25519
    ProxyCommand /opt/homebrew/bin/cloudflared access ssh --hostname %h
```

If `cloudflared` is installed somewhere else, replace `/opt/homebrew/bin/cloudflared` accordingly.

Test:

```bash
ssh ovh-cloudflare
```

Cloudflare Access should open a browser authentication flow and then establish the native SSH session.

Do not remove public SSH until this works and you know how to use OVH KVM/rescue mode.

## 7. Restrict public SSH after Cloudflare access works

Only do this after you have successfully logged in through Cloudflare and know where the OVH KVM console is.

Preferred steady state:

- public Internet: 80/443 for normal Coolify web applications;
- administration: Cloudflare Tunnel + Access;
- SSH daemon: still listening locally for Coolify and the tunnel;
- emergency: OVH KVM/rescue mode.

At the OVH/provider firewall, remove unrestricted public TCP 22. The Cloudflare connector reaches `localhost:22` from inside the VPS, so port 22 does not need to be Internet-accessible.

After changing the provider firewall, verify both:

```bash
ssh ovh-cloudflare
```

and that direct public-IP SSH no longer succeeds from an untrusted network.

## 8. Host firewall note: Docker changes the rules

Ubuntu UFW alone is **not sufficient protection for Docker-published ports**. Docker creates NAT/firewall rules that can route published container traffic before UFW's normal input rules.

Therefore:

- use OVH network filtering where practical;
- avoid publishing application/database ports directly to the host unless required;
- route normal web applications through the Coolify proxy on 80/443;
- review actual listeners regularly with `ss` and `docker ps`;
- if you later need strict host-level filtering of Docker ports, follow Coolify's documented `ufw-docker` path or manage Docker's firewall chains explicitly.

Useful checks:

```bash
sudo ss -lntup
```

After Docker exists:

```bash
docker ps --format 'table {{.Names}}\t{{.Ports}}'
```

## 9. Enable unattended security updates

Ubuntu installs `unattended-upgrades`; verify it is active:

```bash
systemctl status unattended-upgrades --no-pager
```

Review configuration in:

```text
/etc/apt/apt.conf.d/20auto-upgrades
/etc/apt/apt.conf.d/50unattended-upgrades
```

Do not blindly auto-reboot a production host. Apply kernel/reboot-requiring updates deliberately when you can verify the services afterwards.

## 10. Configure 2 GB swap on a 4 GB VPS

For this host, use **2 GB swap** as the baseline. It reduces the chance that a temporary Docker build or deployment spike causes an OOM kill. It is a safety net, not extra RAM for sustained workloads.

Check first:

```bash
swapon --show
```

If there is no existing swap:

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
printf 'vm.swappiness=10\n' | sudo tee /etc/sysctl.d/99-swap.conf
sudo sysctl --system
```

Verify:

```bash
free -h
swapon --show
sysctl vm.swappiness
```

Expected baseline:

```text
swap:       ~2 GiB
swappiness: 10
```

Operational rule: occasional swap usage during a build is acceptable. Regular swap growth, noticeable latency due to swapping, or OOM kills means the workload needs memory limits/tuning or a VPS upgrade.

## 11. Pre-Coolify checks

```bash
cat /etc/os-release
nproc
free -h
df -hT
sudo ss -lntup
systemctl --failed
systemctl status cloudflared --no-pager
```

Do not pre-install Docker from Snap. Coolify explicitly does not support Docker installed through Snap. Let the official Coolify installer install/configure Docker unless you have a specific reason to manage Docker yourself.

## Done when

- [ ] packages updated
- [ ] key-only SSH works for `root`
- [ ] password and keyboard-interactive SSH disabled
- [ ] 2 GB swap configured on a 4 GB VPS
- [ ] Cloudflare Tunnel connector is healthy
- [ ] Cloudflare Access policy protects the SSH hostname
- [ ] root SSH through Cloudflare works
- [ ] unrestricted public TCP 22 removed/restricted
- [ ] OVH KVM/rescue path known
- [ ] Docker is not installed via Snap
- [ ] `systemctl --failed` is clean or understood

Next: [03. Install Coolify](03-coolify.md)

## References

- Coolify OpenSSH: https://coolify.io/docs/core/infrastructure/servers/openssh
- Cloudflare Tunnel: https://developers.cloudflare.com/tunnel/
- Cloudflare SSH through Access: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/ssh/ssh-cloudflared-authentication/
- Docker firewall behaviour: https://docs.docker.com/engine/network/packet-filtering-firewalls/
