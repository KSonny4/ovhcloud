variable "cloudflare_api_token" {
  description = "Cloudflare API token with only the zone, DNS, Tunnel, Access, identity-provider and R2 permissions required by this plan."
  type        = string
  sensitive   = true
}

# Escrow lives outside Terraform (scripts/ensure-service-token.sh + runner);
# no OpenBao provider, variables, or resources remain in this module.
variable "cloudflare_account_id" {
  description = "Cloudflare account ID that owns the Tunnel and R2 bucket."
  type        = string
}

variable "cloudflare_tunnel_secret" {
  description = "Base64-encoded Cloudflare Tunnel secret for the PRESERVED tunnel, supplied ONLY from OpenBao secret/projects/ovhcloud/EDGE_TUNNEL_SECRET (field tunnel_secret) via TF_VAR_cloudflare_tunnel_secret env (memory-only, never files). Fresh per-target tunnels use EDGE_TUNNEL_<NAME> and never touch this variable."
  type        = string
  sensitive   = true
}

variable "domain" {
  description = "Approved Cloudflare-managed canonical domain. Never use example.com or a guessed value."
  type        = string

  validation {
    condition     = !contains(["example.com", "example.invalid", "REPLACE_WITH_APPROVED_DOMAIN"], lower(var.domain)) && can(regex("^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$", lower(var.domain)))
    error_message = "domain must be the approved, fully-qualified Cloudflare zone; documentation placeholders are rejected."
  }
}

variable "ovh_endpoint" {
  description = "OVHcloud API endpoint, normally https://eu.api.ovh.com/1.0."
  type        = string
  default     = "https://eu.api.ovh.com/1.0"
}

variable "ovh_service_name" {
  description = "Existing OVH VPS service name for import and operator records."
  type        = string
  default     = ""
}

variable "ovh_display_name" {
  description = "Display name used only if provisioning a new OVH VPS."
  type        = string
  default     = "ovh-nomad-platform"
}

variable "ovh_subsidiary" {
  description = "OVH billing subsidiary used only if provisioning a new VPS."
  type        = string
  default     = ""
}

variable "ovh_plan_code" {
  description = "OVH VPS plan code used only if provisioning a new VPS."
  type        = string
  default     = "vps-le-2-2-40"
}

variable "ovh_datacenter" {
  description = "OVH VPS datacenter label used only if provisioning a new VPS."
  type        = string
  default     = ""
}

variable "ovh_os" {
  description = "OVH VPS operating system label used only if provisioning a new VPS."
  type        = string
  default     = "Ubuntu 24.04"
}

variable "ovh_ipv4" {
  description = "Approved OVH VPS IPv4 used by Cloudflare origin records; obtain it from ovhcloud CLI and keep the value in ignored tfvars."
  type        = string

  validation {
    condition     = can(regex("^(25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})(\\.(25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})){3}$", var.ovh_ipv4))
    error_message = "ovh_ipv4 must be a valid IPv4 address."
  }
}

variable "provision_ovh_vps" {
  description = "Opt in to ordering an OVH VPS. Keep false for review and import of the existing host."
  type        = bool
  default     = false
}

variable "manage_existing_vps" {
  description = "Record the preserved production VPS as an import-only protected state entry (ovh_vps.preserved). Never true together with provision_ovh_vps."
  type        = bool
  default     = false
}

variable "r2_bucket_name" {
  description = "Private Cloudflare R2 bucket name for Nomad and application backups."
  type        = string
  default     = "ovh-host-backups"
}

variable "access_service_token_name" {
  description = "Stable Cloudflare Access service-token name for noninteractive machine verification."
  type        = string
  default     = "ovh-nomad-machine-verification"
}

variable "access_service_token_duration" {
  # Canonical live value is 8760h: the provider reports duration verbatim, so
  # a "1y" default would plan a perpetual token update on every future run.
  description = "Lifetime of the generated Cloudflare Access service token."
  type        = string
  default     = "8760h"
}

variable "manage_application_wildcard" {
  description = "Whether Terraform should manage the optional Nomad application wildcard DNS record."
  type        = bool
  default     = false
}

variable "admin_emails" {
  description = "Human identities allowed to access the Nomad UI/SSH administrative Access policies."
  type        = set(string)
  default     = []

  validation {
    condition     = length(var.admin_emails) > 0
    error_message = "admin_emails must contain at least one authorized human identity."
  }

  # The platform owner retains human dashboard access by policy: no valid
  # configuration may omit this identity (an apply without it would lock out
  # the required human Access policy). The rehearsal proves omission fails.
  validation {
    condition     = contains(var.admin_emails, "ksonny4@gmail.com")
    error_message = "admin_emails must retain ksonny4@gmail.com for human dashboard access."
  }
}
