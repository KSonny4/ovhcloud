data "cloudflare_zone" "canonical" {
  filter = {
    name   = var.domain
    status = "active"
  }
}

# Cutover tunnel (new VPS). Read-only lookup by ID: the tunnel object
# itself is API-created/API-managed (no tunnel_secret variable exists for
# it); Terraform owns only its config + DNS below. Value from OpenBao:
# bao kv get -field=tunnel_id secret/projects/nomad/EDGE_TUNNEL_NOMAD_148_113_245_89
data "cloudflare_zero_trust_tunnel_cloudflared" "edge_new" {
  account_id = var.cloudflare_account_id
  tunnel_id  = var.edge_tunnel_id
}

data "ovh_vps" "existing" {
  count        = var.ovh_service_name != "" && !var.provision_ovh_vps ? 1 : 0
  service_name = var.ovh_service_name
}

# Retired 2026-09-19: the old production VPS (vps-1525c977) was fully
# decommissioned (all Nomad jobs stopped+purged, service canceled with
# deleteAtExpiration, VM powered off). Its import-only state record was
# removed via `terraform state rm` in the same authorized workflow; the
# block below was deleted with it so no plan can resurrect the reference.
resource "ovh_vps" "platform" {
  count = var.provision_ovh_vps ? 1 : 0

  lifecycle {
    # A newly ordered VPS is a preservation target from birth: never let a
    # refresh or variable change silently replace it. Replacement requires
    # an explicitly authorized follow-up workflow, not this redesign plan.
    prevent_destroy = true
  }

  display_name   = var.ovh_display_name
  ovh_subsidiary = var.ovh_subsidiary

  plan = [{
    duration     = "P1M"
    plan_code    = var.ovh_plan_code
    pricing_mode = "default"
    configuration = [
      {
        label = "vps_datacenter"
        value = var.ovh_datacenter
      },
      {
        label = "vps_os"
        value = var.ovh_os
      }
    ]
  }]
}

resource "cloudflare_dns_record" "nomad" {
  zone_id = data.cloudflare_zone.canonical.id
  name    = "nomad.${var.domain}"
  type    = "CNAME"
  content = "${data.cloudflare_zero_trust_tunnel_cloudflared.edge_new.id}.cfargotunnel.com"
  ttl     = 1
  proxied = true
  comment = "Nomad UI through the Cloudflare Tunnel; managed by Terraform."
}

resource "cloudflare_dns_record" "applications" {
  count   = var.manage_application_wildcard ? 1 : 0
  zone_id = data.cloudflare_zone.canonical.id
  name    = "*.${var.domain}"
  type    = "A"
  content = var.ovh_ipv4
  ttl     = 1
  proxied = true
  comment = "Nomad application wildcard; enable only when the wildcard is approved."
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "admin" {
  account_id    = var.cloudflare_account_id
  name          = "nomad-admin"
  config_src    = "cloudflare"
  tunnel_secret = var.cloudflare_tunnel_secret

  lifecycle {
    # Tunnel deletion would immediately disconnect the only Access-protected
    # entry points. Require an explicit replacement workflow instead.
    prevent_destroy = true
  }
}

resource "cloudflare_dns_record" "ssh" {
  zone_id = data.cloudflare_zone.canonical.id
  name    = "ssh.${var.domain}"
  type    = "CNAME"
  content = "${data.cloudflare_zero_trust_tunnel_cloudflared.edge_new.id}.cfargotunnel.com"
  ttl     = 1
  proxied = true
  comment = "Cloudflare Tunnel hostname for Access-protected SSH."
}

resource "cloudflare_dns_record" "registry" {
  # Private Docker registry hostname (plan-only until an authorized apply).
  # No Access app fronts it: docker push/pull clients are machines, not
  # interactive users.
  zone_id = data.cloudflare_zone.canonical.id
  name    = "registry.${var.domain}"
  type    = "CNAME"
  content = "${data.cloudflare_zero_trust_tunnel_cloudflared.edge_new.id}.cfargotunnel.com"
  ttl     = 1
  proxied = true
  comment = "Private Docker registry (Nomad registry:2)"
}

resource "cloudflare_dns_record" "cognee" {
  # Adopted from API drift 2026-09-19 (was unmanaged on the preserved
  # tunnel); now tracks the cutover tunnel like the other app hostnames.
  # No Access app: the Caddy edge owns machine-client auth.
  zone_id = data.cloudflare_zone.canonical.id
  name    = "cognee.${var.domain}"
  type    = "CNAME"
  content = "${data.cloudflare_zero_trust_tunnel_cloudflared.edge_new.id}.cfargotunnel.com"
  ttl     = 1
  proxied = true
  comment = "Cognee edge (Nomad, cut over 20260919)"
}

resource "cloudflare_dns_record" "unleash" {
  # Resurrected 2026-09-19 on the new VPS (was on a dedicated tunnel whose
  # secret died with the old host). No Access app: Unleash owns login.
  zone_id = data.cloudflare_zone.canonical.id
  name    = "unleash.${var.domain}"
  type    = "CNAME"
  content = "${data.cloudflare_zero_trust_tunnel_cloudflared.edge_new.id}.cfargotunnel.com"
  ttl     = 1
  proxied = true
  comment = "Unleash flags (Nomad, resurrected 20260919)"
}

resource "cloudflare_dns_record" "control" {
  # Resurrected 2026-09-19 (was on the retired admin tunnel).
  zone_id = data.cloudflare_zone.canonical.id
  name    = "control.${var.domain}"
  type    = "CNAME"
  content = "${data.cloudflare_zero_trust_tunnel_cloudflared.edge_new.id}.cfargotunnel.com"
  ttl     = 1
  proxied = true
  comment = "MeowLabs Control (Nomad, resurrected 20260919)"
}

resource "cloudflare_dns_record" "flags_listener" {
  # Resurrected 2026-09-19 (was on the retired admin tunnel). Webhook
  # receiver; secret via FLAGS_WEBHOOK_SECRET at the deploy edge.
  zone_id = data.cloudflare_zone.canonical.id
  name    = "flags-listener.${var.domain}"
  type    = "CNAME"
  content = "${data.cloudflare_zero_trust_tunnel_cloudflared.edge_new.id}.cfargotunnel.com"
  ttl     = 1
  proxied = true
  comment = "Flags webhook listener (Nomad, resurrected 20260919)"
}

resource "cloudflare_dns_record" "dump" {
  # Fallback hostname in the primary account (2026-09-20): the
  # petrzdena.cz CNAME is correct but the edge tunnel-route for the
  # foreign-zone name stays 530/1033 after the dead-tunnel deletion.
  zone_id = data.cloudflare_zone.canonical.id
  name    = "dump.${var.domain}"
  type    = "CNAME"
  content = "${data.cloudflare_zero_trust_tunnel_cloudflared.edge_new.id}.cfargotunnel.com"
  ttl     = 1
  proxied = true
  comment = "Dump app fallback (Nomad) while petrzdena route converges"
}

resource "cloudflare_zero_trust_access_identity_provider" "one_time_pin" {
  account_id = var.cloudflare_account_id
  name       = "One-time PIN"
  type       = "onetimepin"
  config     = {}

  lifecycle {
    # Accidentally replacing the human fallback identity provider would lock
    # out optional dashboard use. Keep replacement explicit.
    prevent_destroy = true
    # The provider API returns an empty name for this built-in IdP; keep the
    # configured value so refresh does not produce perpetual drift.
    ignore_changes = [name]
  }
}

# NOTE: no cloudflare_zero_trust_access_service_token resource exists by
# design (removed 2026-09-19). The provider plans a fresh client_secret on
# ANY update and the API rejects the write (version trap — every plan
# proposed rotation, every apply 400d), so the token object is fully
# API/OpenBao-managed and Terraform references it by stable ID only (the ID
# survives secret rotations; see var.access_service_token_id). Policy
# bindings below still own which apps accept the token.

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "admin" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.admin.id
  source     = "cloudflare"

  config = {
    # Retired 2026-09-20: the old host (sole connector) expired, so every
    # route below went dark (530/1033) and SHADOWED the resurrected names
    # on the new tunnel. All live hostnames moved to edge_new; this object
    # is kept only (prevent_destroy) with a terminal catch-all.
    ingress = [
      {
        service = "http_status:404"
      }
    ]
  }
}

# Cutover tunnel config (new VPS; API-created tunnel, TF-managed config +
# DNS). Carries the migrated + resurrected hostnames. The retired admin
# tunnel object is kept (prevent_destroy) but its connector died with the
# old host, so its keeper/dump/graph-dispatcher routes are dark.
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "edge_new" {
  account_id = var.cloudflare_account_id
  tunnel_id  = data.cloudflare_zero_trust_tunnel_cloudflared.edge_new.id
  source     = "cloudflare"

  config = {
    ingress = [
      {
        # Nomad UI/API on the new origin (loopback-only; served solely
        # through this tunnel hostname).
        hostname = "nomad.${var.domain}"
        service  = "http://localhost:4646"
      },
      {
        hostname = "ssh.${var.domain}"
        service  = "ssh://localhost:22"
      },
      {
        # Private Docker registry, direct to the container port (same
        # pattern as the retired admin rule; no Access app: docker
        # clients are machines).
        hostname = "registry.${var.domain}"
        service  = "http://localhost:5000"
      },
      {
        # Cognee edge (adopted from API drift 2026-09-19). DYNAMIC origin
        # port: the edge job takes a scheduler-assigned loopback port, so
        # every cognee redeploy must re-point this rule (adapted
        # point-tunnel.py) AND update this line, or the hostname 404s.
        # No Access app: the edge owns basic-auth for machine clients.
        hostname = "cognee.${var.domain}"
        service  = "http://localhost:31297"
      },
      {
        # Resurrected 2026-09-19: Unleash flags. DYNAMIC origin port —
        # re-point on every unleash redeploy (cognee pattern). No Access
        # app: Unleash owns login.
        hostname = "unleash.${var.domain}"
        service  = "http://localhost:26065"
      },
      {
        # Resurrected 2026-09-19: MeowLabs Control. DYNAMIC origin port.
        hostname = "control.${var.domain}"
        service  = "http://localhost:30811"
      },
      {
        # Resurrected 2026-09-19: flags webhook listener. DYNAMIC port.
        hostname = "flags-listener.${var.domain}"
        service  = "http://localhost:30018"
      },
      {
        # Resurrected 2026-09-19: dump app. DYNAMIC origin port. DNS for
        # dump.petrzdena.cz lives outside this account — repoint its CNAME
        # to the edge_new tunnel hostname out-of-band (operator).
        hostname = "dump.petrzdena.cz"
        service  = "http://localhost:30692"
      },
      {
        # Fallback in-account hostname (see DNS record above).
        hostname = "dump.${var.domain}"
        service  = "http://localhost:30692"
      },
      {
        service = "http_status:404"
      }
    ]
  }
}

resource "cloudflare_zero_trust_access_application" "nomad" {
  account_id                = var.cloudflare_account_id
  name                      = "Nomad UI"
  domain                    = "nomad.${var.domain}"
  type                      = "self_hosted"
  allowed_idps              = []
  auto_redirect_to_identity = false
  enable_binding_cookie     = true
  options_preflight_bypass  = false
  session_duration          = "24h"
  policies = concat(
    [{
      name       = "Allow machine service token"
      decision   = "non_identity"
      precedence = 1
      include = [{
        service_token = {
          token_id = var.access_service_token_id
        }
      }]
    }],
    [
      for position, email in sort(tolist(var.admin_emails)) : {
        name       = "Allow ${email}"
        decision   = "allow"
        precedence = position + 2
        include = [{
          email = {
            email = email
          }
        }]
      }
    ]
  )
}

resource "cloudflare_zero_trust_access_application" "ssh" {
  account_id                = var.cloudflare_account_id
  name                      = "Nomad SSH Administration"
  domain                    = "ssh.${var.domain}"
  type                      = "self_hosted"
  allowed_idps              = []
  auto_redirect_to_identity = false
  enable_binding_cookie     = true
  options_preflight_bypass  = false
  session_duration          = "24h"
  policies = concat(
    [{
      name       = "Allow machine service token"
      decision   = "non_identity"
      precedence = 1
      include = [{
        service_token = {
          token_id = var.access_service_token_id
        }
      }]
    }],
    [
      for position, email in sort(tolist(var.admin_emails)) : {
        name       = "Allow ${email}"
        decision   = "allow"
        precedence = position + 2
        include = [{
          email = {
            email = email
          }
        }]
      }
    ]
  )
}

# Escrow boundary (deliberate): Terraform owns token identity + policy
# binding only. The secret itself is lifecycle-managed in OpenBao by
# scripts/ensure-service-token.sh (create/rotate/escrow/verify), because
# Cloudflare never reveals the secret back and a Terraform-managed write
# would clobber the good escrow with unreadable state. No vault provider,
# no vault resources, no openbao_ variables/outputs: escrow lives outside
# Terraform, and the live plan converges with zero residual adds.
resource "cloudflare_r2_bucket" "backups" {
  account_id    = var.cloudflare_account_id
  name          = var.r2_bucket_name
  location      = "EEUR"
  storage_class = "Standard"

  lifecycle {
    # Object storage can contain the only restorable copies; guard against
    # accidental bucket deletion until the tested recovery path is promoted.
    prevent_destroy = true
  }
}
