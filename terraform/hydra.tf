# hydra.ts.t11s.net -> juicy-j's tailnet IPs (via data.tailscale_device.juicy_j
# in tailscale.tf).

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
