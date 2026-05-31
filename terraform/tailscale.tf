resource "tailscale_tailnet_key" "dns_nodes" {
  reusable      = true
  ephemeral     = false
  preauthorized = true
  expiry        = 7776000  # 90 days
  description   = "dns-node bootstrap terraform-managed"
  tags          = ["tag:dns-node"]
}
