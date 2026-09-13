# 00. From zero to a working Coolify VPS

Use this page the first time. The numbered documents contain the reasoning, recovery notes and edge cases.

Assumptions:

- you have just bought an OVHcloud VPS;
- nothing important is stored on it yet;
- target OS is Ubuntu 24.04 LTS;
- target platform is Coolify;
- Cloudflare will provide DNS, Tunnel/Access for administration and R2 backup storage;
- the baseline 4 GB VPS will use a 2 GB swap file.

Replace every `<...>` placeholder before running a command. The canonical domain is intentionally not stored in this repository; confirm it in `docs/deployment-plan.md` and provide it through the ignored Terraform variables file before creating DNS or Tunnel resources. `example.com` is documentation-only.

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

### 7. Install Cloudflare Tunnel

In Cloudflare:

1. go to `Networking -> Tunnels`;
2. create a tunnel for this VPS;
3. choose the Linux connector instructions;
4. run Cloudflare's generated `cloudflared` install command on the VPS;
5. wait until the connector shows **Healthy**.

Treat the tunnel token as a secret. Never commit it.

Verify on the VPS:

```bash
systemctl status cloudflared --no-pager
journalctl -u cloudflared -n 50 --no-pager
```

### 8. Route SSH through Cloudflare Access

Add a published application route to the tunnel:

```text
Hostname: ssh.example.com
Service:  SSH
Target:   localhost:22
```

Create a Cloudflare Access self-hosted application for that hostname and allow only your identity/account.

On your Mac/workstation:

```bash
brew install cloudflared
command -v cloudflared
```

Add to `~/.ssh/config`, replacing the `cloudflared` path if Homebrew reports a different one:

```sshconfig
Host ovh-cloudflare
    HostName ssh.example.com
    User root
    IdentityFile ~/.ssh/ovh_vps_ed25519
    ProxyCommand /opt/homebrew/bin/cloudflared access ssh --hostname %h
```

Test:

```bash
ssh ovh-cloudflare
```

The first connection should invoke Cloudflare Access authentication in your browser.

Do not remove public SSH until this works and you know how to use OVH KVM/rescue mode.

### 9. Add 2 GB swap on the 4 GB VPS

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
sysctl vm.swappiness
```

The 2 GB swap file is intentionally a safety buffer for temporary memory spikes. Regular heavy swapping or OOM kills means the machine needs tuning or more RAM.

## Phase 3: install Coolify

### 10. Make sure Docker was not installed from Snap

```bash
snap list 2>/dev/null | grep -i docker || true
```

If that prints a Snap Docker installation, remove it before continuing. The Coolify automatic installer does not support Docker installed through Snap.

### 11. Make the bootstrap ports reachable temporarily

You need:

```text
22/tcp    SSH during bootstrap
80/tcp    HTTP / certificates
443/tcp   HTTPS
8000/tcp  initial Coolify dashboard
```

Direct dashboard functionality can also use 6001/6002. If you need them during initial direct-IP access, expose them only temporarily and preferably only from your source IP.

Provider-level firewalling is preferred because Docker-published ports can bypass ordinary UFW input rules.

### 12. Install Coolify

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

### 13. Create the Coolify administrator immediately

Open:

```text
http://<VPS_IPV4>:8000
```

Create your administrator account immediately. Do not leave an unclaimed Coolify registration page on the public Internet.

### 14. Save the Coolify recovery secret

On the VPS:

```bash
sudo ls -l /data/coolify/source/.env
```

Store the `APP_KEY`, or an encrypted copy of this file, in your external password/secrets manager.

Never commit `/data/coolify/source/.env`.

## Phase 4: give Coolify a proper domain

### 15. Create DNS records in Cloudflare

Example, using `example.com`:

```text
A  coolify  <VPS_IPV4>
A  *        <VPS_IPV4>    # optional wildcard for apps
```

Start with **DNS only** while validating the origin.

Do not add an `AAAA` record until IPv6 has deliberately been tested.

### 16. Configure the Coolify instance URL

In Coolify set the instance URL to:

```text
https://coolify.example.com
```

Verify:

```bash
curl -I https://coolify.example.com
```

Once origin HTTPS works, enable Cloudflare proxying if desired. If enabled, use **Full (strict)** SSL/TLS mode.

For the dashboard, adding a Cloudflare Access policy gives an additional identity gate in front of Coolify's own authentication.

### 17. Close bootstrap/admin ports

Once Coolify works at its HTTPS domain and SSH through Cloudflare is verified, remove direct public access to:

```text
22/tcp
8000/tcp
6001/tcp
6002/tcp
```

Keep the SSH daemon itself running because Coolify uses SSH locally and the Cloudflare tunnel forwards to `localhost:22`.

Normal public surface for this baseline remains:

```text
80/tcp
443/tcp
```

A later fully-tunnelled web architecture can remove those inbound ports too, but it is not required for this baseline.

## Phase 5: prove deployment works

### 18. Deploy a disposable nginx app

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

### 19. Create a private Cloudflare R2 bucket

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

### 20. Add R2 to Coolify

In:

`S3 Storages -> Add`

enter the R2 bucket, endpoint and credentials, then validate it.

### 21. Configure three different backup types

Do all of these separately:

1. **Coolify instance backup -> R2**
2. **each important database backup -> R2**
3. **each irreplaceable persistent volume/directory -> R2**

The Coolify instance backup does not contain all application/database/volume data.

For OmniRoute specifically, back up its `/app/data` persistent mount daily to R2. Because it contains SQLite state, enable **Stop containers while creating the archive** for a safer file-level backup. Keep approximately 30 remote backups and a small number of local copies. See [07. Deploy OmniRoute safely](07-omniroute.md).

### 22. Verify OVH Automated Backup

In OVH:

`Bare Metal Cloud -> Virtual private servers -> <VPS> -> Automated backup`

Verify it is actually enabled on your service and choose a sensible UTC time.

Also install/enable QEMU guest agent if it is not already present:

```bash
sudo apt update
sudo apt install -y qemu-guest-agent
sudo systemctl enable --now qemu-guest-agent
systemctl status qemu-guest-agent --no-pager
```

This OVH backup is an extra recovery layer. Keep R2 backups as the off-provider copy.

## Phase 7: finish hardening

### 23. Audit everything listening publicly

```bash
sudo ss -lntup
docker ps --format 'table {{.Names}}\t{{.Ports}}'
```

Investigate unexpected public bindings, especially databases such as 5432, 3306 and 6379.

Remember that Docker-published ports can bypass normal UFW input filtering.

### 24. Enable notifications

In Coolify configure an external notification channel and enable at least:

- Backup Failure;
- Deployment Failure;
- Server Disk Usage;
- Server Unreachable;
- Container Status Changes.

### 25. Configure conservative Docker cleanup

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

### 26. Run the repo health check

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
- for OmniRoute, restore `/app/data` into a disposable test deployment at least once;
- confirm the `APP_KEY` exists outside the VPS;
- confirm OVH Automated Backup exists;
- perform at least one disposable application-data restore test.

Then the platform is ready for real workloads.

## Final intended state

```text
Internet
   |
Cloudflare
   |-- DNS / proxy for public web apps
   |-- Tunnel + Access for SSH administration
   `-- R2 backups
   |
80,443 only to public web path
   |
OVH VPS
   |-- Ubuntu 24.04
   |-- 2 GB swap on the 4 GB baseline
   |-- cloudflared outbound admin tunnel
   |-- Coolify
   |-- Docker workloads
   `-- backups ----------> Cloudflare R2

Human SSH: Cloudflare Access -> Tunnel -> localhost:22
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
- [OmniRoute deployment](07-omniroute.md)
