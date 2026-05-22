# Configures the bpg/proxmox provider and the MinIO S3 backend.
# State key is scoped to this root module only — each future root module
# (e.g. opnsense/) gets its own key so a destroy in one can't touch another.

terraform {

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.73.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }

  backend "s3" {
    bucket = "terraformstate-test"
    key    = "vms/terraform.tfstate"
    region = "local"

    endpoints = {
      s3 = "http://<minio-host>:9000"   # set to your MinIO endpoint
    }

    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_path_style              = true
    insecure                    = true  # remove once MinIO has a proper TLS cert
  }
}

provider "proxmox" {
  endpoint  = "https://<proxmox-host>:8006/"
  api_token = var.proxmox_api_token
  insecure  = true  # remove once Proxmox has a valid cert

  ssh {
    agent    = false
    username = "root"

    node {
      name    = "amy"
      address = "<proxmox-node-1-ip>"
    }
    node {
      name    = "farnsworth"
      address = "<proxmox-node-2-ip>"
    }
  }

}