# ---------- us-west-2 ----------

resource "aws_vpc" "dns_usw2" {
  provider                         = aws.usw2
  cidr_block                       = "10.42.0.0/16"
  assign_generated_ipv6_cidr_block = true
  enable_dns_support               = true
  enable_dns_hostnames             = true
  tags = { Name = "dns-usw2" }
}

resource "aws_subnet" "dns_usw2" {
  provider                        = aws.usw2
  vpc_id                          = aws_vpc.dns_usw2.id
  cidr_block                      = "10.42.0.0/24"
  ipv6_cidr_block                 = cidrsubnet(aws_vpc.dns_usw2.ipv6_cidr_block, 8, 0)
  availability_zone               = "us-west-2a"
  assign_ipv6_address_on_creation = true
  tags = { Name = "dns-usw2" }
}

resource "aws_internet_gateway" "dns_usw2" {
  provider = aws.usw2
  vpc_id   = aws_vpc.dns_usw2.id
  tags     = { Name = "dns-usw2" }
}

resource "aws_route_table" "dns_usw2" {
  provider = aws.usw2
  vpc_id   = aws_vpc.dns_usw2.id
  route {
    ipv6_cidr_block = "::/0"
    gateway_id      = aws_internet_gateway.dns_usw2.id
  }
  tags = { Name = "dns-usw2" }
}

resource "aws_route_table_association" "dns_usw2" {
  provider       = aws.usw2
  subnet_id      = aws_subnet.dns_usw2.id
  route_table_id = aws_route_table.dns_usw2.id
}

# ---------- us-east-2 ----------

resource "aws_vpc" "dns_use2" {
  provider                         = aws.use2
  cidr_block                       = "10.43.0.0/16"
  assign_generated_ipv6_cidr_block = true
  enable_dns_support               = true
  enable_dns_hostnames             = true
  tags = { Name = "dns-use2" }
}

resource "aws_subnet" "dns_use2" {
  provider                        = aws.use2
  vpc_id                          = aws_vpc.dns_use2.id
  cidr_block                      = "10.43.0.0/24"
  ipv6_cidr_block                 = cidrsubnet(aws_vpc.dns_use2.ipv6_cidr_block, 8, 0)
  availability_zone               = "us-east-2a"
  assign_ipv6_address_on_creation = true
  tags = { Name = "dns-use2" }
}

resource "aws_internet_gateway" "dns_use2" {
  provider = aws.use2
  vpc_id   = aws_vpc.dns_use2.id
  tags     = { Name = "dns-use2" }
}

resource "aws_route_table" "dns_use2" {
  provider = aws.use2
  vpc_id   = aws_vpc.dns_use2.id
  route {
    ipv6_cidr_block = "::/0"
    gateway_id      = aws_internet_gateway.dns_use2.id
  }
  tags = { Name = "dns-use2" }
}

resource "aws_route_table_association" "dns_use2" {
  provider       = aws.use2
  subnet_id      = aws_subnet.dns_use2.id
  route_table_id = aws_route_table.dns_use2.id
}
