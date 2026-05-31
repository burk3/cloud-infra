resource "aws_ssm_parameter" "tailscale_authkey_usw2" {
  provider = aws.usw2
  name     = "/dns-nodes/tailscale-authkey"
  type     = "SecureString"
  value    = tailscale_tailnet_key.dns_nodes.key
  tags     = { Name = "dns-nodes-tailscale-authkey" }
}

resource "aws_ssm_parameter" "tailscale_authkey_use2" {
  provider = aws.use2
  name     = "/dns-nodes/tailscale-authkey"
  type     = "SecureString"
  value    = tailscale_tailnet_key.dns_nodes.key
  tags     = { Name = "dns-nodes-tailscale-authkey" }
}
