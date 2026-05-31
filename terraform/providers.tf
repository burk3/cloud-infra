provider "aws" {
  alias  = "usw2"
  region = "us-west-2"
}

provider "aws" {
  alias  = "use2"
  region = "us-east-2"
}

provider "tailscale" {
  oauth_client_id     = var.tailscale_oauth_client_id
  oauth_client_secret = var.tailscale_oauth_client_secret
  tailnet             = var.tailnet
}
