# hydra.ts.t11s.net -> juicy-j's tailnet IPs, sourced live from the tailscale
# provider so a tailnet IP rotation on that device propagates with `terraform
# apply` instead of needing a `variables.tf` edit.

data "tailscale_device" "juicy_j" {
  name = "juicy-j.${var.tailnet}"
}

locals {
  juicy_j_tailnet_v4 = [for a in data.tailscale_device.juicy_j.addresses : a if !strcontains(a, ":")]
  juicy_j_tailnet_v6 = [for a in data.tailscale_device.juicy_j.addresses : a if strcontains(a, ":")]
}

resource "aws_route53_record" "hydra_a" {
  provider = aws.usw2
  zone_id  = aws_route53_zone.ts.zone_id
  name     = "hydra.${var.ts_dns_zone}"
  type     = "A"
  ttl      = 60
  records  = local.juicy_j_tailnet_v4
}

resource "aws_route53_record" "hydra_aaaa" {
  provider = aws.usw2
  zone_id  = aws_route53_zone.ts.zone_id
  name     = "hydra.${var.ts_dns_zone}"
  type     = "AAAA"
  ttl      = 60
  records  = local.juicy_j_tailnet_v6
}
