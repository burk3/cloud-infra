resource "tailscale_tailnet_key" "dns_nodes" {
  reusable      = true
  ephemeral     = false
  preauthorized = true
  expiry        = 7776000  # 90 days
  description   = "dns-node bootstrap terraform-managed"
  tags          = ["tag:dns-node"]
}

# Tailnet addresses for on-network hosts, sourced live from the tailscale
# provider so IP rotations propagate via `terraform apply` instead of
# secrets.auto.tfvars edits.

data "tailscale_device" "juicy_j" {
  name = "juicy-j.${var.tailnet}"
}

data "tailscale_device" "turing" {
  name = "turing.${var.tailnet}"
}

locals {
  juicy_j_tailnet_v4 = [for a in data.tailscale_device.juicy_j.addresses : a if !strcontains(a, ":")]
  juicy_j_tailnet_v6 = [for a in data.tailscale_device.juicy_j.addresses : a if strcontains(a, ":")]
  turing_tailnet_v4  = [for a in data.tailscale_device.turing.addresses : a if !strcontains(a, ":")]
  turing_tailnet_v6  = [for a in data.tailscale_device.turing.addresses : a if strcontains(a, ":")]
}
