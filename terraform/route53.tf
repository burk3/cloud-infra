# Single private hosted zone associated with both VPCs.
# Must be created in one region but is queried from both via the VPC resolver
# once each VPC is associated.

resource "aws_route53_zone" "ts" {
  provider = aws.usw2
  name     = var.ts_dns_zone

  vpc {
    vpc_id     = aws_vpc.dns_usw2.id
    vpc_region = "us-west-2"
  }

  vpc {
    vpc_id     = aws_vpc.dns_use2.id
    vpc_region = "us-east-2"
  }

  comment = "Private zone for ts.t11s.net — served via CoreDNS on the tailnet"
}

# turing
resource "aws_route53_record" "turing_a" {
  provider = aws.usw2
  zone_id  = aws_route53_zone.ts.zone_id
  name     = "turing.${var.ts_dns_zone}"
  type     = "A"
  ttl      = 60
  records  = local.turing_tailnet_v4
}

resource "aws_route53_record" "turing_aaaa" {
  provider = aws.usw2
  zone_id  = aws_route53_zone.ts.zone_id
  name     = "turing.${var.ts_dns_zone}"
  type     = "AAAA"
  ttl      = 60
  records  = local.turing_tailnet_v6
}

# juicy-j
resource "aws_route53_record" "juicy_j_a" {
  provider = aws.usw2
  zone_id  = aws_route53_zone.ts.zone_id
  name     = "juicy-j.${var.ts_dns_zone}"
  type     = "A"
  ttl      = 60
  records  = local.juicy_j_tailnet_v4
}

resource "aws_route53_record" "juicy_j_aaaa" {
  provider = aws.usw2
  zone_id  = aws_route53_zone.ts.zone_id
  name     = "juicy-j.${var.ts_dns_zone}"
  type     = "AAAA"
  ttl      = 60
  records  = local.juicy_j_tailnet_v6
}
