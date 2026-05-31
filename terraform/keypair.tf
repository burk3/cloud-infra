# Operator SSH key for debugging access on the DNS nodes. Once the cattle
# join the tailnet and CoreDNS is healthy, this isn't strictly needed — but
# it's the cheapest break-glass path while the user-data path is still being
# stabilized. Reachable from bronson (which has v6).

resource "aws_key_pair" "operator_usw2" {
  provider   = aws.usw2
  key_name   = "operator"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFssPVej1nLwAQwHSCUbA3h5Cqz2kj1lSKPmdl+6SIAn burke@freddie-kane"
}

resource "aws_key_pair" "operator_use2" {
  provider   = aws.use2
  key_name   = "operator"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFssPVej1nLwAQwHSCUbA3h5Cqz2kj1lSKPmdl+6SIAn burke@freddie-kane"
}
