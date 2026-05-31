# Inbound SSH over IPv6 for operator break-glass via bronson. Once the
# cattle join the tailnet and we're confident in the bootstrap path, this
# can be tightened or removed entirely.

resource "aws_security_group" "operator_ssh_usw2" {
  provider    = aws.usw2
  name        = "operator-ssh"
  description = "Allow SSH from anywhere over IPv6 (operator break-glass)"
  vpc_id      = aws_vpc.dns_usw2.id

  ingress {
    description      = "SSH from IPv6 internet"
    from_port        = 22
    to_port          = 22
    protocol         = "tcp"
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    description      = "Allow all egress"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = { Name = "operator-ssh-usw2" }
}

resource "aws_security_group" "operator_ssh_use2" {
  provider    = aws.use2
  name        = "operator-ssh"
  description = "Allow SSH from anywhere over IPv6 (operator break-glass)"
  vpc_id      = aws_vpc.dns_use2.id

  ingress {
    description      = "SSH from IPv6 internet"
    from_port        = 22
    to_port          = 22
    protocol         = "tcp"
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    description      = "Allow all egress"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = { Name = "operator-ssh-use2" }
}
