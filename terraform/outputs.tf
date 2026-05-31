output "dns_usw2_instance_id" {
  value = aws_instance.dns_usw2.id
}

output "dns_usw2_ipv6_addresses" {
  value = aws_instance.dns_usw2.ipv6_addresses
}

output "dns_use2_instance_id" {
  value = aws_instance.dns_use2.id
}

output "dns_use2_ipv6_addresses" {
  value = aws_instance.dns_use2.ipv6_addresses
}

output "tailscale_key_id" {
  value     = tailscale_tailnet_key.dns_nodes.id
  sensitive = true
}

output "route53_zone_id" {
  value = aws_route53_zone.ts.zone_id
}
