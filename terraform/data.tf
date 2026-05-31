data "aws_ami" "detsys_nixos_usw2" {
  provider    = aws.usw2
  most_recent = true
  owners      = ["535002876703"]

  filter {
    name   = "name"
    values = ["determinate/nixos/epoch-1/*"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

data "aws_ami" "detsys_nixos_use2" {
  provider    = aws.use2
  most_recent = true
  owners      = ["535002876703"]

  filter {
    name   = "name"
    values = ["determinate/nixos/epoch-1/*"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}
