terraform {
  required_version = ">= 1.6.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.47"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
