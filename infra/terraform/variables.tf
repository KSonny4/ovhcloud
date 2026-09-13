variable "cloudflare_api_token" {
  description = "Cloudflare API token with only the zone, DNS, Tunnel, Access, identity-provider and R2 permissions required by this plan."
  type        = string
  sensitive   = true
}

variable "openbao_address" {
  description = "Remote OpenBao address used to escrow generated deployment credentials."
  type        = string
  default     = "https://secrets.pkubelka.cz"

  validation {
    condition     = can(regex("^https://", var.openbao_address))
    error_message = "openbao_address must use the remote HTTPS OpenBao endpoint."
  }
}

variable "openbao_token" {
  description = "OpenBao runner token supplied out-of-band; never commit or print it."
  type        = string
  sensitive   = true
}

variable "openbao_kv_mount" {
  description = "OpenBao KV v2 mount containing generated deployment credentials."
  type        = string
  default     = "secret"
}

variable "openbao_service_token_path" {
  description = "OpenBao KV path for the generated Cloudflare machine Access credential."
  type        = string
  default     = "projects/ovhcloud/COOLIFY_ACCESS_SERVICE_TOKEN"
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID that owns the Tunnel and R2 bucket."
  type        = string
}

variable "cloudflare_tunnel_secret" {
  description = "Base64-encoded Cloudflare Tunnel secret, supplied by the external secret manager."
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
  default     = "ovh-coolify-platform"
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

variable "r2_bucket_name" {
  description = "Private Cloudflare R2 bucket name for Coolify and application backups."
  type        = string
  default     = "ovh-coolify-backups"
}

variable "access_service_token_name" {
  description = "Stable Cloudflare Access service-token name for noninteractive machine verification."
  type        = string
  default     = "ovh-coolify-machine-verification"
}

variable "access_service_token_duration" {
  description = "Lifetime of the generated Cloudflare Access service token."
  type        = string
  default     = "1y"
}

variable "manage_application_wildcard" {
  description = "Whether Terraform should manage the optional Coolify application wildcard DNS record."
  type        = bool
  default     = false
}

variable "admin_emails" {
  description = "Human identities allowed to access the Coolify/SSH administrative Access policies."
  type        = set(string)
  default     = []

  validation {
    condition     = length(var.admin_emails) > 0
    error_message = "admin_emails must contain at least one authorized human identity."
  }
}
