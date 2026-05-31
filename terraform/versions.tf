terraform {
  required_version = ">= 1.10"

  backend "s3" {
    bucket       = "burk3-cloud-infra-tfstate"
    key          = "cloud-infra.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.29.0"
    }
  }
}
