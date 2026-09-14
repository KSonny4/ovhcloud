data "cloudflare_zone" "canonical" {
  filter = {
    name   = var.domain
    status = "active"
  }
}

data "ovh_vps" "existing" {
  count        = var.ovh_service_name != "" && !var.provision_ovh_vps ? 1 : 0
  service_name = var.ovh_service_name
}

# The preserved production VPS as a managed, protected state record. This
# resource is import-only: it brings the existing service under Terraform
# state protection without modeling (or permitting) any mutation. Combined
# with prevent_destroy + ignore_changes = all, no plan can replace, update,
# or destroy it; removal from management requires explicitly deleting this
# block AND the state entry in a separately authorized workflow.
resource "ovh_vps" "preserved" {
  count = var.manage_existing_vps && !var.provision_ovh_vps ? 1 : 0

  lifecycle {
    prevent_destroy = true
    ignore_changes  = all

    precondition {
      condition     = !(var.manage_existing_vps && var.provision_ovh_vps)
      error_message = "manage_existing_vps and provision_ovh_vps are mutually exclusive."
    }
  }

  # ovh_subsidiary is the provider's only required argument; its value is
  # inert here because every attribute is ignored after import.
  ovh_subsidiary = var.ovh_subsidiary
}

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

resource "cloudflare_dns_record" "coolify" {
  zone_id = data.cloudflare_zone.canonical.id
  name    = "coolify.${var.domain}"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.admin.id}.cfargotunnel.com"
  ttl     = 1
  proxied = true
  comment = "Coolify dashboard through the Cloudflare Tunnel; managed by Terraform."
}

resource "cloudflare_dns_record" "applications" {
  count   = var.manage_application_wildcard ? 1 : 0
  zone_id = data.cloudflare_zone.canonical.id
  name    = "*.${var.domain}"
  type    = "A"
  content = var.ovh_ipv4
  ttl     = 1
  proxied = true
  comment = "Coolify application wildcard; enable only when the wildcard is approved."
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "admin" {
  account_id    = var.cloudflare_account_id
  name          = "coolify-admin"
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
  content = "${cloudflare_zero_trust_tunnel_cloudflared.admin.id}.cfargotunnel.com"
  ttl     = 1
  proxied = true
  comment = "Cloudflare Tunnel hostname for Access-protected SSH."
}

resource "cloudflare_dns_record" "omniroute" {
  # OmniRoute staging hostname (Pi migration; serves the Coolify deployment).
  # No Access app fronts it: the gateway API must stay machine-accessible.
  zone_id = data.cloudflare_zone.canonical.id
  name    = "omniroute.${var.domain}"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.admin.id}.cfargotunnel.com"
  ttl     = 1
  proxied = true
  comment = "OmniRoute Coolify staging (Pi migration 20260914)"
}

resource "cloudflare_dns_record" "fabric" {
  # Operator-added application hostname (adopted 2026-09-14 alongside the
  # tunnel route above; live record had no comment).
  zone_id = data.cloudflare_zone.canonical.id
  name    = "fabric.${var.domain}"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.admin.id}.cfargotunnel.com"
  ttl     = 1
  proxied = true
  comment = "fabric rollout 20260914"
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

resource "cloudflare_zero_trust_access_service_token" "machine" {
  account_id = var.cloudflare_account_id
  name       = var.access_service_token_name
  duration   = var.access_service_token_duration
  enabled    = true

  # The token secret itself is lifecycle-managed in OpenBao (rotation happens
  # via dashboard/API + re-escrow, Cloudflare never reveals the secret back).
  # Terraform tracks the token identity/policy binding only: the secret version
  # recorded at import must never be reset (the API rejects a lower version).
  # client_secret/expires_at are provider-decided and intentionally absent here.
  lifecycle {
    ignore_changes = [client_secret_version]
  }
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "admin" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.admin.id
  source     = "cloudflare"

  config = {
    ingress = [
      {
        # Dashboard realtime websocket (Soketi): the dashboard page dials
        # wss://<host>/app/<key> (same-origin 443 — getRealtime() returns
        # null for port-less URLs), and the web terminal dials
        # wss://<host>/terminal/ws. The tunnel bypasses Traefik (which has
        # the matching PathPrefix routes for direct-origin access), so
        # these paths must fan out to the realtime ports here. Path rules
        # MUST precede the bare-hostname rule (first match wins).
        # cloudflared matches path as a PREFIX: "/app/" (trailing slash)
        # covers /app/<key> but must NOT steal /applications* (API) — a
        # "/app/*" pattern was proven live to hijack every /app*-prefixed
        # path (API 404s from Soketi instead of Laravel).
        hostname = "coolify.${var.domain}"
        path     = "/app/"
        service  = "http://localhost:6001"
      },
      {
        hostname = "coolify.${var.domain}"
        path     = "/terminal/ws/*"
        service  = "http://localhost:6002"
      },
      {
        hostname = "coolify.${var.domain}"
        service  = "http://localhost:8000"
      },
      {
        hostname = "ssh.${var.domain}"
        service  = "ssh://localhost:22"
      },
      {
        # Operator-added application route (adopted 2026-09-14 after live
        # drift; serves the user app through the origin proxy on :80).
        hostname = "fabric.${var.domain}"
        service  = "http://localhost:80"
      },
      {
        # OmniRoute staging (Pi migration 20260914): same origin-proxy
        # pattern as fabric; traefik routes by Host to the app. No Access
        # policy here — the gateway API stays machine-accessible.
        hostname = "omniroute.${var.domain}"
        service  = "http://localhost:80"
      },
      {
        service = "http_status:404"
      }
    ]
  }
}

resource "cloudflare_zero_trust_access_application" "coolify" {
  account_id                = var.cloudflare_account_id
  name                      = "Coolify Dashboard"
  domain                    = "coolify.${var.domain}"
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
          token_id = cloudflare_zero_trust_access_service_token.machine.id
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
  name                      = "Coolify SSH Administration"
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
          token_id = cloudflare_zero_trust_access_service_token.machine.id
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
