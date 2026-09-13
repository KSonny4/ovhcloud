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

## 5. Install Tailscale

Tailscale becomes the normal administrative path so public SSH can later be restricted.

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

Authenticate using the URL printed by the command.

Verify:

```bash
tailscale status
tailscale ip -4
```

From your workstation, test normal OpenSSH over the Tailscale address:

```bash
ssh -i ~/.ssh/ovh_vps_ed25519 root@<TAILSCALE_IPV4>
```

You can optionally enable Tailscale SSH later with:

```bash
sudo tailscale set --ssh
```

That introduces Tailscale SSH policy/ACL semantics, so it is not required for this baseline. Plain OpenSSH over the encrypted tailnet is sufficient.

## 6. Restrict public SSH after Tailscale works

Only do this after you have successfully logged in over Tailscale and know where the OVH KVM console is.

Preferred steady state:

- public Internet: 80/443 only
- administration: Tailscale
- emergency: OVH KVM/rescue mode

At the OVH/provider firewall, remove unrestricted public TCP 22 or restrict it to a trusted source IP. Keep the host SSH daemon listening normally so the Tailscale path still works.

## 7. Host firewall note: Docker changes the rules

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

## 8. Enable unattended security updates

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

## 9. Optional swap for VPS-1-sized hosts

If the host has 4 GB RAM, a small swap file can reduce the chance that a temporary Docker build spike kills the host. It is a safety net, not extra RAM.

Check first:

```bash
swapon --show
```

If there is no swap and you want 2 GB:

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
```

## 10. Pre-Coolify checks

```bash
cat /etc/os-release
nproc
free -h
df -hT
sudo ss -lntup
systemctl --failed
```

Do not pre-install Docker from Snap. Coolify explicitly does not support Docker installed through Snap. Let the official Coolify installer install/configure Docker unless you have a specific reason to manage Docker yourself.

## Done when

- [ ] packages updated
- [ ] key-only SSH works for `root`
- [ ] password and keyboard-interactive SSH disabled
- [ ] Tailscale is connected
- [ ] root SSH over Tailscale works
- [ ] OVH KVM/rescue path known
- [ ] Docker is not installed via Snap
- [ ] optional swap configured if wanted
- [ ] `systemctl --failed` is clean or understood

Next: [03. Install Coolify](03-coolify.md)

## References

- Coolify OpenSSH: https://coolify.io/docs/core/infrastructure/servers/openssh
- Tailscale Linux: https://tailscale.com/docs/install/linux
- Docker firewall behaviour: https://docs.docker.com/engine/network/packet-filtering-firewalls/
