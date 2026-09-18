variable "cloudflare_api_token" {
  description = "Admin token (TF_VAR_cloudflare_api_token, from OpenBao ADMIN_CLOUDFLARE)."
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID."
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Zone ID holding the fresh hostnames."
  type        = string
}

variable "service_token_id" {
  description = "Shared machine service-token UUID (OpenBao EDGE_ACCESS_SERVICE_TOKEN.token_id); referenced by nested policies, never managed here."
  type        = string
}

variable "admin_emails" {
  description = "Human UI identities (must retain ksonny4@gmail.com)."
  type        = list(string)

  validation {
    condition     = contains(var.admin_emails, "ksonny4@gmail.com")
    error_message = "admin_emails must retain ksonny4@gmail.com."
  }
}
