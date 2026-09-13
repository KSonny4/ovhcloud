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

resource "ovh_vps" "platform" {
  count = var.provision_ovh_vps ? 1 : 0

  lifecycle {
    # The current VPS is a preservation target: never let a refresh or variable
    # change silently replace it. Replacement requires an explicitly authorized
    # follow-up workflow, not this redesign plan.
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

resource "cloudflare_zero_trust_access_identity_provider" "one_time_pin" {
  account_id = var.cloudflare_account_id
  name       = "One-time PIN"
  type       = "onetimepin"
  config     = {}

  lifecycle {
    # Accidentally replacing the human fallback identity provider would lock
    # out optional dashboard use. Keep replacement explicit.
    prevent_destroy = true
  }
}

resource "cloudflare_zero_trust_access_service_token" "machine" {
  account_id = var.cloudflare_account_id
  name       = var.access_service_token_name
  duration   = var.access_service_token_duration
  enabled    = true
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "admin" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.admin.id
  source     = "cloudflare"

  config = {
    ingress = [
      {
        hostname = "coolify.${var.domain}"
        service  = "http://localhost:8000"
      },
      {
        hostname = "ssh.${var.domain}"
        service  = "ssh://localhost:22"
      },
      {
        service = "http_status:404"
      }
    ]
  }
}

resource "cloudflare_zero_trust_access_application" "coolify" {
  account_id                = var.cloudflare_account_id
  name                      = "Coolify administration"
  domain                    = "coolify.${var.domain}"
  type                      = "self_hosted"
  allowed_idps              = [cloudflare_zero_trust_access_identity_provider.one_time_pin.id]
  auto_redirect_to_identity = false
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
  name                      = "OVH SSH administration"
  domain                    = "ssh.${var.domain}"
  type                      = "self_hosted"
  allowed_idps              = [cloudflare_zero_trust_access_identity_provider.one_time_pin.id]
  auto_redirect_to_identity = false
  session_duration          = "24h"
  policies = [
    for position, email in sort(tolist(var.admin_emails)) : {
      name       = "Allow ${email}"
      decision   = "allow"
      precedence = position + 1
      include = [{
        email = {
          email = email
        }
      }]
    }
  ]
}

resource "vault_kv_secret_v2" "access_service_token" {
  mount = var.openbao_kv_mount
  name  = var.openbao_service_token_path

  data_json = jsonencode({
    client_id     = cloudflare_zero_trust_access_service_token.machine.client_id
    client_secret = cloudflare_zero_trust_access_service_token.machine.client_secret
    duration      = var.access_service_token_duration
  })
}

resource "cloudflare_r2_bucket" "backups" {
  account_id    = var.cloudflare_account_id
  name          = var.r2_bucket_name
  location      = "weur"
  storage_class = "Standard"

  lifecycle {
    # Object storage can contain the only restorable copies; guard against
    # accidental bucket deletion until the tested recovery path is promoted.
    prevent_destroy = true
  }
}
