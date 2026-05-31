# Single global role used in both regions (IAM is global).

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dns_node" {
  name               = "dns-node"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

data "aws_iam_policy_document" "ssm_read_dns_nodes" {
  statement {
    effect  = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]
    resources = [
      # Wildcard region/account — both regions share the same parameter
      # names. Covers /dns-nodes/tailscale-authkey.
      "arn:aws:ssm:*:*:parameter/dns-nodes/*",
    ]
  }
}

resource "aws_iam_role_policy" "dns_node_ssm" {
  name   = "ssm-read-dns-nodes"
  role   = aws_iam_role.dns_node.id
  policy = data.aws_iam_policy_document.ssm_read_dns_nodes.json
}

data "aws_iam_policy_document" "cache_read" {
  # Read access to the closure cache bucket.
  statement {
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = [
      "${aws_s3_bucket.cache.arn}/*",
    ]
  }
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.cache.arn]
  }
}

resource "aws_iam_role_policy" "dns_node_cache" {
  name   = "cache-read"
  role   = aws_iam_role.dns_node.id
  policy = data.aws_iam_policy_document.cache_read.json
}

resource "aws_iam_instance_profile" "dns_node" {
  name = "dns-node"
  role = aws_iam_role.dns_node.name
}
