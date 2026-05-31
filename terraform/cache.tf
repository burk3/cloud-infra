# S3 bucket used as a Nix binary cache for the DNS node closures.
#
# Operator pushes signed aarch64-linux closures here from this machine
# (private signing key in ~/.config/nix-cache/burk3-dns-cache.secret);
# the instances substitute over public IPv6 via the dual-stack endpoint.
# Closures are content-addressed and signed by `burk3-dns-cache:...`, so
# the bucket can stay private with IAM-gated reads from the dns_node role.
#
# us-west-2 was chosen arbitrarily; us-east-2 instances fetch cross-region
# via the AWS backbone. Cost is negligible at our scale (a few hundred MB).

resource "aws_s3_bucket" "cache" {
  provider = aws.usw2
  bucket   = "burk3-dns-cache"
}

resource "aws_s3_bucket_public_access_block" "cache" {
  provider                = aws.usw2
  bucket                  = aws_s3_bucket.cache.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Closures are immutable (content-addressed). No versioning, no lifecycle —
# the bucket grows monotonically as we publish new releases. If it ever
# gets unwieldy, add a lifecycle rule with `expiration` to clear out store
# paths older than some threshold.
