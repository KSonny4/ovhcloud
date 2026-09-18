> **LEGACY / BREAK-GLASS ONLY.** This 26-step manual runbook is **not**
> the canonical provisioning path — see [00-quickstart.md](00-quickstart.md)
> for the single-command noninteractive provisioner. Keep this file for
> emergencies only (total lockout, automation unreachable, OVH KVM/rescue).

# 00. From zero to a working Nomad VPS (legacy manual, break-glass only)

Use this page the first time. The numbered documents contain the reasoning, recovery notes and edge cases.

Assumptions:

- you have just bought an OVHcloud VPS;
- nothing important is stored on it yet;
- target OS is Ubuntu 24.04 LTS;
- target platform is Nomad;
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

Root key-based SSH is intentionally retained while password login is disabled (break-glass access independent of any control plane).

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

## Phase 3: install Nomad

### 10. Make sure Docker was not installed from Snap

```bash
snap list 2>/dev/null | grep -i docker || true
```

If that prints a Snap Docker installation, remove it before continuing. The Nomad Docker driver needs a normally-installed Docker Engine, never Snap.

### 11. Make the bootstrap ports reachable temporarily

You need:

```text
22/tcp    SSH during bootstrap
80/tcp    HTTP / certificates
443/tcp   HTTPS
```

Nomad's API/UI (4646) stays loopback-only from the start — it is served through the Cloudflare Tunnel, never direct.

Provider-level firewalling is preferred because Docker-published ports can bypass ordinary UFW input rules.

### 12. Install Nomad (pinned, checksum-verified)

Become root if needed:

```bash
sudo -i
```

Install the pinned release (currently 2.0.6; confirm at
https://releases.hashicorp.com/nomad/):

```bash
NOMAD_VERSION=2.0.6
WORKDIR="$(mktemp -d)"; cd "$WORKDIR"
curl -fsSLO "https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_linux_amd64.zip"
curl -fsSLO "https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_SHA256SUMS"
grep "nomad_${NOMAD_VERSION}_linux_amd64.zip" "nomad_${NOMAD_VERSION}_SHA256SUMS" | sha256sum -c -
unzip -o "nomad_${NOMAD_VERSION}_linux_amd64.zip" -d /usr/local/bin
chmod +x /usr/local/bin/nomad
mkdir -p /opt/nomad /etc/nomad.d
```

Write a single-node config in `/etc/nomad.d/nomad.hcl` (server +
client, `bootstrap_expect = 1`, loopback bind, ACL enabled — see
[03](03-nomad.md)), install the systemd unit, enable and start it.

Verify:

```bash
nomad server members
nomad node status -short
docker ps
ss -lntup
```

### 13. ACL-bootstrap immediately

With nothing else listening, bootstrap once:

```bash
export NOMAD_ADDR=http://127.0.0.1:4646
nomad acl bootstrap -json
```

Escrow the bootstrap token + gossip key in OpenBao
(`secret/projects/nomad/NOMAD_BOOTSTRAP`) at once — without them a
rebuilt cluster cannot be re-administered. Do not leave an unclaimed
cluster API on the network.

### 14. Save the Nomad recovery material

The escrowed ACL token and gossip key are the recovery secret. Verify
they exist outside the VPS (OpenBao readback of field names only).

Never commit token or key material to Git.

## Phase 4: give Nomad a proper domain

### 15. Create DNS records in Cloudflare

Example, using `example.com` (tunnel hostnames — no origin A records):

```text
CNAME  nomad  <tunnel-id>.cfargotunnel.com  (proxied)
CNAME  *      <tunnel-id>.cfargotunnel.com  # optional wildcard for apps (proxied)
```

Do not add an `AAAA` record until IPv6 has deliberately been tested.

### 16. Point the tunnel at Nomad

Tunnel ingress for the UI hostname:

```text
nomad.example.com -> http://localhost:4646
```

Verify through Cloudflare (service-token headers for machine checks):

```bash
curl -I https://nomad.example.com/v1/status/leader
```

Use **Full (strict)** SSL/TLS mode. Put a Cloudflare Access policy in
front of the UI hostname for human authentication.

### 17. Close bootstrap/admin ports

Once the UI serves at its HTTPS domain and SSH through Cloudflare is verified, remove direct public access to:

```text
22/tcp
```

Nomad ports 4646/4647/4648 were never opened — they stay loopback-only.
Keep the SSH daemon itself running because the Cloudflare tunnel forwards to `localhost:22`.

Normal public surface for this baseline remains:

```text
80/tcp
443/tcp
```

A later fully-tunnelled web architecture can remove those inbound ports too, but it is not required for this baseline.

## Phase 5: prove deployment works

### 18. Deploy a disposable nginx job

Jobspec `smoke.nomad.hcl` (Docker driver, `nginx:alpine`, one group,
service check on `/`):

```bash
export NOMAD_ADDR=http://127.0.0.1:4646 NOMAD_TOKEN=<bootstrap-token>
nomad job run smoke.nomad.hcl
nomad job status smoke
```

Expose it through the edge job + DNS, open its domain, then stop and
purge it (`nomad job stop -purge smoke`) if you do not need it.

If this succeeds, Nomad, Docker, proxying, DNS and TLS are basically working.

## Phase 6: configure off-machine backups

### 19. Create a private Cloudflare R2 bucket

Suggested name:

```text
ovh-host-backups
```

Create an R2 token scoped to that bucket with Object Read & Write access.

Store:

- Access Key ID;
- Secret Access Key;
- S3 endpoint;

in your external secrets manager.

### 20. Keep R2 out of the control plane

Do NOT attach the R2 bucket to any control-plane storage feature: the
host timer is the single backup plane and pulls credentials memory-only
from OpenBao on every run. A second destination would reintroduce an
at-rest credential copy for zero coverage gain.

### 21. Configure three different backup types

Do all of these separately:

1. **Nomad snapshots -> R2**
2. **each important database backup -> R2**
3. **each irreplaceable persistent volume/directory -> R2**

A Nomad snapshot does not contain application/database/volume data — those ride the same timer separately.

For OmniRoute specifically, back up its `/app/data` host volume daily to R2. Because it contains SQLite state, stop the allocation while creating the archive for a safer file-level backup. Keep approximately 30 remote backups and a small number of local copies. See [07. Deploy OmniRoute safely](07-omniroute.md).

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

Configure an external notification channel (the plane has no built-in
notifier) and alert on at least:

- Backup Failure (timer unit + nightly R2 keys);
- Deployment Failure (failed/degraded allocations);
- Server Disk Usage;
- Server Unreachable;
- Allocation status changes.

### 25. Configure conservative Docker cleanup

Nomad GC handles dead allocations; for Docker artifacts keep this
baseline (manual or a small timer, never blind):

```text
weekly or at 80% disk
unused volume deletion: NEVER automatically
unused network deletion: only when understood
image retention: running jobs' images + one previous
```

Do not casually run `docker system prune -a --volumes` on a server containing state.

### 26. Run the repo health check

Clone this repository on your workstation or server if desired, then:

```bash
bash scripts/healthcheck.sh
```

It is deliberately read-only and never prints secret material.

## Phase 8: test recovery before trusting the server

Before moving anything important onto the VPS:

- trigger one Nomad snapshot backup and verify it exists in R2;
- trigger one database backup and verify it exists in R2;
- back up one persistent mount if you use one;
- for OmniRoute, restore `/app/data` into a disposable test deployment at least once;
- confirm the bootstrap token + gossip key exist outside the VPS;
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
   |-- Nomad (server + client)
   |-- Docker workloads (Nomad jobs)
   `-- backups ----------> Cloudflare R2

Human SSH: Cloudflare Access -> Tunnel -> localhost:22
Emergency access: OVH KVM / rescue mode
Whole-server safety net: OVH Automated Backup
```

## Continue reading

- [OVH-specific details](01-ovh-vps.md)
- [Host hardening details](02-host-bootstrap.md)
- [Nomad details](03-nomad.md)
- [Cloudflare/R2 details](04-cloudflare.md)
- [Backup and restore details](05-backup-recovery.md)
- [Operations and upgrades](06-operations.md)
- [OmniRoute deployment](07-omniroute.md)
