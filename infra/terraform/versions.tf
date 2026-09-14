terraform {
  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    ovh = {
      source  = "ovh/ovh"
      version = "~> 0.42"
    }
  }

  # Production state uses an encrypted, locked S3-compatible backend.
  # Values are supplied via -backend-config="backend.hcl" (see backend.hcl.example).
  # Never commit backend.hcl or any state file. Disposable rehearsal may use
  # local state only with an isolated working directory and -backend=false init.
  backend "s3" {}
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

provider "ovh" {
  endpoint = var.ovh_endpoint
}
