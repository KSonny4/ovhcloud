# Pending imports — control-panel prod edge (2026-09-18, API-made state)

Per `docs/nomad-service.md` §5 (engineering-guidance): API-made state gets
import notes for the IaC owner same day. This file is those notes. Nothing
here is applied — the IaC owner runs the import + plan.

## What changed live tonight (certain — verified against API + VPS journal)

1. **DNS CNAME `control.pkubelka.cz`** (created 2026-09-18T20:59:41Z via
   `POST /zones/0fcca39cc6516b8e23971bd717c0e9ca/dns_records`):
   - Record ID: `49cd3e1aaa676f962ff8f91faa6f1e04`
   - Zone: `pkubelka.cz` (zone ID `0fcca39cc6516b8e23971bd717c0e9ca`)
   - Content: `b145382e-d1cc-4e60-b910-3de56fa9ce2c.cfargotunnel.com`
     (nomad-admin tunnel), proxied, ttl auto
   - Comment: `control-panel Nomad service, 2026-09-18`
   - Status: resolving worldwide; edge serves 200 (verified 2026-09-18 ~22:00 UTC)
2. **nomad-admin tunnel ingress v19** (`PUT .../cfd_tunnel/b145382e-d1cc-4e60-b910-3de56fa9ce2c/configurations`,
   connector confirmed `Updated to new configuration`, version 19):
   prior 14 rules **plus**
   - `control.pkubelka.cz` → `http://localhost:8081` (control-panel Nomad
     service; port 8081 because 8080 is bound on all interfaces on the VPS)

Backups: VPS connector journal
(`journalctl -u cloudflared | grep "Updated to new configuration"`, v19
dumped 2026-09-18); full 15-rule ingress JSON also held on the operator Mac
(`/tmp/nomad-admin-ingress-backup.json` v18 + `/tmp/nomad-admin-ingress-new.json`
v19 as PUT) — ask the operator for a copy before relying on /tmp.

## HCL to add (`infra/terraform/main.tf`)

DNS record, same style as the `registry` block:

```hcl
resource "cloudflare_dns_record" "control" {
  # Control-panel prod UI/API on Nomad (deployed 2026-09-18; adopted live).
  # No Access app fronts it: GET routes are public, POST routes are
  # ingest-token gated — same rule as the registry/OmniRoute hostnames.
  zone_id = data.cloudflare_zone.canonical.id
  name    = "control.${var.domain}"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.admin.id}.cfargotunnel.com"
  ttl     = 1
  proxied = true
  comment = "control-panel Nomad service, 2026-09-18"
}
```

Ingress rule — insert into `cloudflare_zero_trust_tunnel_cloudflared_config.admin`
`config.ingress`, immediately before the `http_status:404` catch-all:

```hcl
      {
        # Control panel (Nomad control-panel job, loopback :8081 — :8080 is
        # taken on all interfaces on the VPS). Added live 2026-09-18 as
        # tunnel config v19; adopted verbatim here.
        hostname = "control.${var.domain}"
        service  = "http://localhost:8081"
      },
```

No import needed for the tunnel config itself: resource
`cloudflare_zero_trust_tunnel_cloudflared_config.admin` is already managed;
`plan` should show exactly this one-rule diff after the HCL edit.

## Import + verify (IaC owner runs)

```bash
terraform import cloudflare_dns_record.control \
  0fcca39cc6516b8e23971bd717c0e9ca/49cd3e1aaa676f962ff8f91faa6f1e04
terraform plan   # expect: +1 dns_record (no changes), +1 ingress rule, nothing else
```

Then: `curl -s -o /dev/null -w "%{http_code}\n" https://control.pkubelka.cz/healthz`
→ `200` (and `/api/v1/topology`, `/topology`).

## ⚠ Pre-existing drift warning (certain — do NOT apply blindly)

Live tunnel config contains **three `coolify.pkubelka.cz` rules**
(`:6001` path `/app/`, `:6002` path `/terminal/ws/*`, `:8000`) that are
**absent from this module** (verified: full v19 journal dump vs `main.tf`
grep, 2026-09-18). A `plan`/`apply` of the above will also propose
**deleting** those rules — killing Coolify. Adopt the coolify rules into
`main.tf` first (same verbatim pattern as the adopted keeper/dump rules),
or reconcile with whoever owns them, before applying anything from this note.

## Certain vs assumed

- Certain: record IDs, rule list, v19 effective config, 200 probes, coolify absence from `main.tf`.
- Assumed: nothing in this note. The `terraform import` ID format
  `{zone_id}/{record_id}` follows cloudflare provider v5 (`~> 5.0` pinned
  in `versions.tf`); if the provider version has moved on, re-check import
  syntax before running.
