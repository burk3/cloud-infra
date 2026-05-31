# EBS-backed /var/lib/tailscale per host. The volume persists across
# instance recreations so the tailscaled node identity (and tailnet IP)
# stays stable. AZ-pinned to the host's subnet AZ.

resource "aws_ebs_volume" "dns_usw2_tsdata" {
  provider          = aws.usw2
  availability_zone = aws_subnet.dns_usw2.availability_zone
  size              = 1
  type              = "gp3"
  encrypted         = true
  tags              = { Name = "dns-usw2-tsdata" }
}

resource "aws_volume_attachment" "dns_usw2_tsdata" {
  provider                       = aws.usw2
  device_name                    = "/dev/sdf"
  volume_id                      = aws_ebs_volume.dns_usw2_tsdata.id
  instance_id                    = aws_instance.dns_usw2.id
  stop_instance_before_detaching = true
}

resource "aws_ebs_volume" "dns_use2_tsdata" {
  provider          = aws.use2
  availability_zone = aws_subnet.dns_use2.availability_zone
  size              = 1
  type              = "gp3"
  encrypted         = true
  tags              = { Name = "dns-use2-tsdata" }
}

resource "aws_volume_attachment" "dns_use2_tsdata" {
  provider                       = aws.use2
  device_name                    = "/dev/sdf"
  volume_id                      = aws_ebs_volume.dns_use2_tsdata.id
  instance_id                    = aws_instance.dns_use2.id
  stop_instance_before_detaching = true
}
