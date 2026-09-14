terraform {
  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }

  # Fresh-environment state uses the same encrypted R2 backend with a
  # DIFFERENT key (see backend.hcl.example). Values via backend.hcl (ignored).
  backend "s3" {}
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
