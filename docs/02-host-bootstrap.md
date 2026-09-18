# 02. Bootstrap and secure Ubuntu

The automated path is `scripts/bootstrap-vps.sh`, executed on the target by
the provisioner (`scripts/run-remote-provision.sh --stages bootstrap`, see
[00. Quickstart](00-quickstart.md)). It performs every step below and
verifies each one, failing closed. Do not run these by hand on a fresh host.

## 1. Automated path (primary)

What the bootstrap stage does and verifies:

- OS update + `full-upgrade`, base packages (`ca-certificates curl git jq`,
  `openssh-server`, `unattended-upgrades`); reboot only if required.
- Hostname + UTC timezone.
- Key-only SSH for `ubuntu` and `root` (`prohibit-password`), password and
  keyboard-interactive auth disabled, via a validated `sshd_config` drop-in.
- UFW baseline (no public web ports: 80/443 denied; tunneled app traffic
  only; SSH is Tunnel-served, never public).
- Docker Engine from the official repository (never Snap) + `hello-world`
  verification.
- 2 GB swap baseline (swappiness 10) on small hosts.
- Unattended security updates enabled (no blind auto-reboot).
- Pre-Nomad checks: OS, CPU/RAM/disk, listeners, clean `systemctl --failed`.

Verify read-only any time:

```bash
ssh -i ~/.ssh/ovh_nomad_ed25519 ubuntu@<host> \
  'cat /etc/os-release; systemctl --failed --no-pager; sudo ss -lntup | head'
bash scripts/healthcheck.sh
```

Notes that remain true and are enforced by the automation:

- Ubuntu UFW alone does not constrain Docker-published ports (Docker inserts
  NAT rules ahead of UFW) — proven live 2026-09-14 when external probes
  reached :80/:443/:4646/:4647/:4648 despite UFW DENY. The compensation is
  `scripts/ensure-docker-firewall.sh`: scoped DROP of new external ingress
  in Docker's DOCKER-USER hook chain (established traffic RETURNed first;
  loopback for cloudflared and inter-container traffic unaffected; host SSH
  untouched), persisted by a `docker-firewall.service` unit (After=docker).
  Verify with `--check-only` plus the DROP packet counter (background
  internet scanning keeps it incrementing — self-proving), and with
  `scripts/verify-nomad-live.sh` (edge 200, server members, workloads,
  timer — fail-closed). Avoid publishing app/database ports to the host;
  route web apps through the Nomad edge job; audit listeners with `ss` and
  `docker ps`.
- Keep a second SSH session open while changing access (the automation does;
  so should you, in break-glass).

## Done when

- [x] packages updated, key-only SSH for `ubuntu` + `root`
- [x] 2 GB swap configured (small hosts)
- [x] Docker Engine verified (`hello-world`)
- [x] `systemctl --failed` clean
- [x] KVM/rescue path known (see [01](01-ovh-vps.md))

Next: Nomad is installed by the provisioner (`--stages nomad`);
see [03](03-nomad.md) for what that covers.

## Appendix: break-glass (automation unavailable)

SSH hardening drop-in (validate before restart):

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
sudo sshd -t && sudo systemctl restart ssh
```

Test from a second terminal before closing the first:

```bash
ssh -i ~/.ssh/ovh_nomad_ed25519 ubuntu@<host>
ssh -i ~/.ssh/ovh_nomad_ed25519 root@<host>
```

Swap baseline (4 GB host):

```bash
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile \
  && sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

## References

- OpenSSH server: https://www.openssh.com/manual.html
- Docker firewall behaviour: https://docs.docker.com/engine/network/packet-filtering-firewalls/
