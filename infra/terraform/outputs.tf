output "existing_ovh_vps_ips" {
  description = "IPs reported by the read-only OVH VPS data source when an existing service name is supplied."
  value       = var.ovh_service_name != "" && !var.provision_ovh_vps ? data.ovh_vps.existing[0].ips : []
}

output "managed_ovh_vps_service_name" {
  description = "Service name of a newly ordered VPS, available only after an authorized apply."
  value       = var.provision_ovh_vps ? ovh_vps.platform[0].service_name : null
}

output "cloudflare_access_service_token_id" {
  description = "Cloudflare Access service-token ID used for noninteractive machine verification."
  value       = cloudflare_zero_trust_access_service_token.machine.id
}

output "cloudflare_tunnel_id" {
  description = "Cloudflare admin tunnel ID; treat as infrastructure metadata, not a credential."
  value       = cloudflare_zero_trust_tunnel_cloudflared.admin.id
}

output "backup_bucket_name" {
  description = "Private Cloudflare R2 bucket used for Nomad/application backups."
  value       = cloudflare_r2_bucket.backups.name
}
