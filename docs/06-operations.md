# 06. Operations and upgrades

This is the ongoing runbook after the VPS is live.

## 1. Fast health check

Run:

```bash
uptime
free -h
swapon --show
df -hT
systemctl --failed
sudo ss -lntup
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
docker stats --no-stream
docker system df
systemctl status cloudflared --no-pager
```

A helper script with these read-only checks is in [`scripts/healthcheck.sh`](../scripts/healthcheck.sh).

## 2. What to watch

### Disk is the first thing to take seriously

Docker images, build cache, logs, databases and volumes all share the VPS disk.

Operational thresholds used by this runbook:

```text
< 70%   normal
70-80%  investigate trend
80-85%  cleanup / capacity action soon
> 85%   urgent on a small production host
```

These are operating recommendations, not OVH/Nomad guarantees.

Check:

```bash
df -hT
docker system df
du -xh /opt/nomad --max-depth=2 2>/dev/null | sort -h | tail -30
```

### Memory

```bash
free -h
swapon --show
docker stats --no-stream
journalctl -k --since '24 hours ago' | grep -i -E 'oom|out of memory|killed process' || true
```

The 2 GB swap file on the 4 GB baseline host is there for short-lived spikes. Regular OOM kills or sustained/heavy swap usage mean the box is undersized or a workload has no sensible limits.

### CPU / load

```bash
uptime
ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -20
```

Short build spikes are fine. Sustained saturation that affects the control plane is a reason to add resources or move heavy builds/workloads elsewhere.

## 3. Alerting

There is no built-in notification center on this plane — alerting is the
operator's external channel (see [05](05-backup-recovery.md) section 10).
Grafana-managed rules committed here (import-ready, routed to the
`keeper-telegram` contact): `grafana/alerts/pg-shared.json` covers pg-shared
and the host disk thresholds (see [03](03-nomad.md) section 8).
At minimum, watch:

- Deployment failures (`nomad job status` degraded/failed allocations)
- Backup failures (`host-backup.timer` unit failure, missing nightly R2 keys)
- Allocation status changes and restarts
- Server disk usage (thresholds in section 2)
- Server unreachable (tunnel + Access checks)
- Docker cleanup failures
- Pending OS security updates

A backup that fails its R2 upload is a backup failure — treat the timer
unit and the nightly R2 keys as the alert source until an external channel
exists.

## 4. Docker cleanup

Prefer conservative, explicit cleanup over aggressive ad-hoc pruning.
Nomad's own GC handles dead allocations; for Docker artifacts keep a safe
baseline:

```text
prune cadence: weekly or at 80% disk
delete unused volumes: NEVER automatically
delete unused networks: only when unreferenced and understood
image retention: keep the running jobs' images + one previous
```

An "unused" Docker volume can still contain valuable data from a
stopped/removed allocation — treat every volume as guilty of holding data
until proven otherwise.

Do **not** casually run:

```bash
docker system prune -a --volumes
```

on this host.

If disk is filling, first inspect:

```bash
docker system df
docker ps -a
docker volume ls
```

Then use a targeted cleanup whose effects you understand.

## 5. OS patching

At least monthly, and sooner for important security updates:

```bash
sudo apt update
apt list --upgradable
```

Then during a maintenance window:

```bash
sudo apt full-upgrade -y
```

Before rebooting:

- verify backups;
- check no critical deployment/migration is running;
- note current container health.

If reboot required:

```bash
sudo reboot
```

After reconnecting through Cloudflare Access:

```bash
systemctl --failed
systemctl status cloudflared --no-pager
docker ps
curl -I https://nomad.example.com
```

Then check a few real applications.

## 6. Nomad updates

For a host that matters, use controlled updates rather than surprise
auto-updates. Nomad has no auto-updater — updates are a deliberate binary
swap.

Before updating Nomad:

1. verify the latest R2 snapshot backup;
2. verify important DB backups;
3. review the Nomad upgrade guide for the target version;
4. ensure no active deployment;
5. note the current Nomad version;
6. take an OVH snapshot if the change feels risky and the option is enabled;
7. replace the binary (checksum-verified, same procedure as install), restart the agent;
8. verify UI, server members, allocations, edge job, apps and backups.

## 7. When to upgrade VPS-1 -> VPS-2

Upgrade when the constraint is persistent rather than a one-off spike. Examples:

- builds regularly cause the VPS to swap heavily;
- OOM kills happen;
- CPU stays saturated during normal traffic;
- the Nomad UI/API becomes sluggish while builds run;
- disk is too small even after sensible Docker cleanup/log retention;
- several databases/services now share the host.

Do not upgrade only because a single build briefly uses 100% CPU or touches swap.

## 8. OVH in-place VPS upgrade

Current OVH documentation says higher-resource upgrades are applied to the **existing VPS** and preserve:

- IP address;
- server data;
- backups/snapshots;
- attached software licence, subject to provider terms.

The upgrade is effective immediately once applied. Available choices depend on the VPS range/model.

Control Panel path:

`Bare Metal Cloud -> Virtual private servers -> <VPS> -> Home -> Your configuration`

From there OVH exposes higher vCore/memory/storage options when available.

### Before upgrade

- [ ] verify R2 backups
- [ ] verify OVH Automated Backup
- [ ] take optional OVH snapshot before a major change
- [ ] record `lsblk` and `df -hT`
- [ ] record `free -h`, `swapon --show` and `nproc`
- [ ] ensure no deployment or database migration is running

### After upgrade

```bash
nproc
free -h
swapon --show
lsblk
df -hT
docker ps
```

If storage increased, the virtual disk may be larger while the partition/filesystem is still the old size. OVH explicitly notes that you may need to expand partitions after a storage upgrade. Follow the OVH repartitioning guide for the actual disk layout instead of guessing device names.

Reference:

https://docs.ovhcloud.com/en/guides/bare-metal-cloud/virtual-private-servers/upgrade-resources

## 9. Downsizing

Plan downsizing as a migration to another smaller VPS rather than assuming the same one-click path exists in reverse.

That means:

1. provision smaller VPS;
2. bootstrap securely;
3. restore/migrate Nomad state and workloads;
4. switch DNS;
5. verify;
6. keep the old VPS until recovery confidence is high;
7. cancel the old VPS.

Do not discover this constraint after building around a temporary large server.

## 10. Exposure audit

Run regularly:

```bash
sudo ss -lntup
docker ps --format 'table {{.Names}}\t{{.Ports}}'
```

For normal Nomad web apps, public reachability lives at the Cloudflare edge; the origin host exposes no public web ports (UFW denies 80/443, tunneled traffic only). Public TCP 22 should not be part of the steady-state path because SSH administration goes through Cloudflare Tunnel + Access.

Treat entries like these as a reason to investigate:

```text
0.0.0.0:5432
0.0.0.0:6379
0.0.0.0:3306
```

unless publishing that database was deliberate and separately secured.

Remember: Docker-published ports can bypass normal UFW input rules.

## 11. Monthly checklist

- [ ] package updates reviewed/applied
- [ ] Nomad update status reviewed
- [ ] R2 backup executions inspected
- [ ] one recent DB/volume backup spot-checked
- [ ] OVH Automated Backup present
- [ ] disk usage checked
- [ ] Docker cleanup results checked
- [ ] memory/OOM/swap history checked
- [ ] public listeners reviewed; TCP 22 is not unintentionally public
- [ ] Cloudflare Tunnel connector health reviewed
- [ ] Cloudflare Access policies and authorised identities reviewed
- [ ] stale apps/databases removed deliberately
- [ ] secrets/access for departed/unused integrations revoked

## 12. Before any risky infrastructure change

Use this mini-protocol:

```text
1. Can I restore?
2. Is the latest off-host backup good?
3. Do I know how to reach OVH KVM/rescue mode?
4. Is a snapshot useful here?
5. What exact verification proves the change worked?
6. What is the rollback?
```

Do not make a destructive storage/firewall/SSH change if those answers are unknown.

## References

- OVH VPS upgrade: https://docs.ovhcloud.com/en/guides/bare-metal-cloud/virtual-private-servers/upgrade-resources
- Nomad upgrades: https://developer.hashicorp.com/nomad/docs/upgrade
- Nomad Docker driver GC: https://developer.hashicorp.com/nomad/docs/drivers/docker#garbage-collection
- Cloudflare Tunnel: https://developers.cloudflare.com/tunnel/
- Cloudflare SSH through Access: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/ssh/ssh-cloudflared-authentication/
- Docker firewall behaviour: https://docs.docker.com/engine/network/packet-filtering-firewalls/
