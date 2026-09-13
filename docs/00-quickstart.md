# 00. From zero to a working Coolify VPS

Use this page the first time. The numbered documents contain the reasoning, recovery notes and edge cases.

Assumptions:

- you have just bought an OVHcloud VPS;
- nothing important is stored on it yet;
- target OS is Ubuntu 24.04 LTS;
- target platform is Coolify;
- Cloudflare will provide DNS and R2 backup storage;
- Tailscale will be the normal administration path.

Replace every `<...>` placeholder before running a command.

## Phase 1: prepare OVH

### 1. Reinstall to Ubuntu 24.04 LTS if needed

In OVHcloud Control Panel:

`Bare Metal Cloud -> Virtual private servers -> <your VPS>`

If the VPS is already Ubuntu 24.04 LTS and contains nothing you care about, keep it. Otherwise reinstall now.

Before changing SSH/firewall settings, locate:

- KVM console;
- rescue mode;
- VPS public IPv4;
- VPS service name.

### 2. Generate a dedicated SSH key locally

On your Mac/workstation:

```bash
ssh-keygen -t ed25519 -a 100 \
  -f ~/.ssh/ovh_vps_ed25519 \
  -C "ovh-vps"
```

Use a passphrase.

Public key:

```bash
cat ~/.ssh/ovh_vps_ed25519.pub
```

Add the **public** key during OVH reinstall if offered.

Never put the private key in Git.

### 3. SSH to the machine

Ubuntu's OVH account is normally `ubuntu`:

```bash
ssh -i ~/.ssh/ovh_vps_ed25519 ubuntu@<VPS_IPV4>
```

Verify:

```bash
cat /etc/os-release
nproc
free -h
lsblk
df -hT
```

Stop here if the resources or OS are not what you ordered.

## Phase 2: bootstrap the operating system

### 4. Update everything

```bash
sudo apt update
sudo DEBIAN_FRONTEND=noninteractive apt full-upgrade -y
sudo apt install -y \
  ca-certificates curl git jq vim htop tmux \
  openssh-server unattended-upgrades
```

If `/var/run/reboot-required` exists:

```bash
sudo reboot
```

Reconnect afterwards.

### 5. Give root the tested SSH public key

Coolify manages its localhost server over SSH, so root key-based SSH is intentionally retained while password login is disabled.

On the VPS:

```bash
sudo install -d -m 700 /root/.ssh
sudo touch /root/.ssh/authorized_keys
sudo chmod 600 /root/.ssh/authorized_keys
cat ~/.ssh/authorized_keys | sudo tee -a /root/.ssh/authorized_keys >/dev/null
sudo sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys
```

From a **second local terminal**, verify before touching SSH configuration:

```bash
ssh -i ~/.ssh/ovh_vps_ed25519 root@<VPS_IPV4>
```

Do not proceed until that works.

### 6. Disable password SSH

On the VPS:

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

sudo sshd -t
sudo systemctl restart ssh
```

From the second terminal, test root and ubuntu key login again.

Keep the original session open until both tests pass.

### 7. Install Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

Authenticate using the printed URL.

Get the tailnet IP:

```bash
tailscale ip -4
```

From your workstation:

```bash
ssh -i ~/.ssh/ovh_vps_ed25519 root@<TAILSCALE_IPV4>
```

Do not remove public SSH until this works and you know how to use OVH KVM/rescue mode.

### 8. Optional: add 2 GB swap on a 4 GB VPS

Check first:

```bash
swapon --show
```

If empty:

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

## Phase 3: install Coolify

### 9. Make sure Docker was not installed from Snap

```bash
snap list 2>/dev/null | grep -i docker || true
```

If that prints a Snap Docker installation, remove it before continuing. The Coolify automatic installer does not support Docker installed through Snap.

### 10. Make the bootstrap ports reachable temporarily

You need:

```text
22/tcp    SSH during bootstrap
80/tcp    HTTP / certificates
443/tcp   HTTPS
8000/tcp  initial Coolify dashboard
```

Direct dashboard functionality can also use 6001/6002. If you need them during initial direct-IP access, expose them only temporarily and preferably only from your source IP.

Provider-level firewalling is preferred because Docker-published ports can bypass ordinary UFW input rules.

### 11. Install Coolify

Become root if needed:

```bash
sudo -i
```

Run the official installer:

```bash
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
```

Verify:

```bash
docker ps
ss -lntup
```

### 12. Create the Coolify administrator immediately

Open:

```text
http://<VPS_IPV4>:8000
```

Create your administrator account immediately. Do not leave an unclaimed Coolify registration page on the public Internet.

### 13. Save the Coolify recovery secret

On the VPS:

```bash
sudo ls -l /data/coolify/source/.env
```

Store the `APP_KEY`, or an encrypted copy of this file, in your external password/secrets manager.

Never commit `/data/coolify/source/.env`.

## Phase 4: give Coolify a proper domain

### 14. Create DNS records in Cloudflare

Example, using `example.com`:

```text
A  coolify  <VPS_IPV4>
A  *        <VPS_IPV4>    # optional wildcard for apps
```

Start with **DNS only** while validating the origin.

Do not add an `AAAA` record until IPv6 has deliberately been tested.

### 15. Configure the Coolify instance URL

In Coolify set the instance URL to:

```text
https://coolify.example.com
```

Verify:

```bash
curl -I https://coolify.example.com
```

Once origin HTTPS works, Cloudflare proxying is optional. If enabled, use **Full (strict)** SSL/TLS mode.

### 16. Close bootstrap/direct dashboard ports

Once Coolify works at its HTTPS domain, direct public access to these should go away:

```text
8000/tcp
6001/tcp
6002/tcp
```

Normal final public surface:

```text
80/tcp
443/tcp
```

For SSH, use Tailscale. Restrict/remove unrestricted public TCP 22 at the provider firewall after verifying Tailscale and OVH recovery access.

## Phase 5: prove deployment works

### 17. Deploy a disposable nginx app

In Coolify:

1. create project `platform-smoke-test`;
2. add a Docker Image application;
3. image: `nginx:alpine`;
4. container port: `80`;
5. deploy;
6. open its generated/custom domain.

Delete it afterwards if you do not need it.

If this succeeds, Coolify, Docker, proxying, DNS and TLS are basically working.

## Phase 6: configure off-machine backups

### 18. Create a private Cloudflare R2 bucket

Suggested name:

```text
ovh-coolify-backups
```

Create an R2 token scoped to that bucket with Object Read & Write access.

Store:

- Access Key ID;
- Secret Access Key;
- S3 endpoint;

in your external secrets manager.

### 19. Add R2 to Coolify

In:

`S3 Storages -> Add`

enter the R2 bucket, endpoint and credentials, then validate it.

### 20. Configure three different backup types

Do all of these separately:

1. **Coolify instance backup -> R2**
2. **each important database backup -> R2**
3. **each irreplaceable persistent volume/directory -> R2**

The Coolify instance backup does not contain all application/database/volume data.

### 21. Verify OVH Automated Backup

In OVH:

`Bare Metal Cloud -> Virtual private servers -> <VPS> -> Automated backup`

Current OVH VPS plans document one daily Automated Backup as a free service option. Verify it is actually enabled on your service and choose a sensible UTC time.

Also install/enable QEMU guest agent if it is not already present:

```bash
sudo apt update
sudo apt install -y qemu-guest-agent
sudo systemctl enable --now qemu-guest-agent
systemctl status qemu-guest-agent --no-pager
```

This OVH backup is an extra recovery layer. Keep R2 backups as the off-provider copy.

## Phase 7: finish hardening

### 22. Audit everything listening publicly

```bash
sudo ss -lntup
docker ps --format 'table {{.Names}}\t{{.Ports}}'
```

Investigate unexpected public bindings, especially databases such as 5432, 3306 and 6379.

Remember that Docker-published ports can bypass normal UFW input filtering.

### 23. Enable notifications

In Coolify configure an external notification channel and enable at least:

- Backup Failure;
- Deployment Failure;
- Server Disk Usage;
- Server Unreachable;
- Container Status Changes.

### 24. Configure conservative Docker cleanup

In:

`Servers -> localhost -> Docker Cleanup`

Baseline:

```text
daily check
80% disk threshold
unused volume deletion: OFF
unused network deletion: OFF
application image retention: ON
```

Do not casually run `docker system prune -a --volumes` on a server containing state.

### 25. Run the repo health check

Clone this repository on your workstation or server if desired, then:

```bash
bash scripts/healthcheck.sh
```

It is deliberately read-only and does not print Coolify `.env` contents.

## Phase 8: test recovery before trusting the server

Before moving anything important onto the VPS:

- trigger one Coolify instance backup and verify it exists in R2;
- trigger one database backup and verify it exists in R2;
- back up one persistent mount if you use one;
- confirm the `APP_KEY` exists outside the VPS;
- confirm OVH Automated Backup exists;
- perform at least one disposable application-data restore test.

Then the platform is ready for real workloads.

## Final intended state

```text
Internet
   |
Cloudflare DNS / optional proxy
   |
80,443 only
   |
OVH VPS
   |-- Ubuntu 24.04
   |-- Tailscale admin path
   |-- Coolify
   |-- Docker workloads
   `-- backups ----------> Cloudflare R2

Emergency access: OVH KVM / rescue mode
Whole-server safety net: OVH Automated Backup
```

## Continue reading

- [OVH-specific details](01-ovh-vps.md)
- [Host hardening details](02-host-bootstrap.md)
- [Coolify details](03-coolify.md)
- [Cloudflare/R2 details](04-cloudflare.md)
- [Backup and restore details](05-backup-recovery.md)
- [Operations and upgrades](06-operations.md)
