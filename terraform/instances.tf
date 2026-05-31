locals {
  # User-data fetches the pre-built system toplevel from the operator-managed
  # S3 binary cache, sets it as the system profile, and runs
  # switch-to-configuration. No eval, no FlakeHub login, no flake resolution
  # — all of that happened on the operator's workstation. The toplevel store
  # path and public signing key are baked in at terraform-apply time.
  #
  # `--option trusted-public-keys ...` injects the verification key for this
  # one nix copy invocation since the instance doesn't trust the burk3-dns-cache
  # signature until after the first successful activation (the on-host
  # dns-server module adds it to nix.settings.trusted-public-keys).
  #
  # The instance IAM role grants s3:GetObject on the cache bucket; awscli /
  # nix's S3 substituter discovers credentials from IMDS.
  user_data_template = <<-EOT
    #!/usr/bin/env bash
    set -euxo pipefail
    # Retry nix copy a few times: occasional IPv6 socket timeouts to the S3
    # dualstack endpoint cause individual NAR fetches to fail mid-bulk-copy.
    # Each retry resumes (paths already in /nix/store are skipped).
    for attempt in 1 2 3 4 5; do
      if nix copy \
          --from '${var.dns_cache_url}' \
          --option trusted-public-keys 'cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= ${var.dns_cache_public_key}' \
          TOPLEVEL_PATH_PLACEHOLDER; then
        break
      fi
      echo "nix copy attempt $attempt failed; retrying in 5s..."
      sleep 5
      if [ "$attempt" -eq 5 ]; then
        echo "nix copy still failing after 5 attempts; aborting" >&2
        exit 1
      fi
    done
    nix-env --profile /nix/var/nix/profiles/system --set TOPLEVEL_PATH_PLACEHOLDER
    /nix/var/nix/profiles/system/bin/switch-to-configuration switch
  EOT
}

resource "aws_instance" "dns_usw2" {
  provider               = aws.usw2
  ami                    = data.aws_ami.detsys_nixos_usw2.id
  instance_type          = "t4g.nano"
  subnet_id              = aws_subnet.dns_usw2.id
  iam_instance_profile   = aws_iam_instance_profile.dns_node.name
  key_name               = aws_key_pair.operator_usw2.key_name
  vpc_security_group_ids = [aws_security_group.operator_ssh_usw2.id]

  ipv6_address_count          = 1
  associate_public_ip_address = false

  metadata_options {
    http_endpoint               = "enabled"
    http_protocol_ipv6          = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    delete_on_termination = true
  }

  user_data                   = replace(local.user_data_template, "TOPLEVEL_PATH_PLACEHOLDER", var.dns_usw2_toplevel_path)
  user_data_replace_on_change = true

  tags = { Name = "dns-usw2" }

  depends_on = [
    aws_ssm_parameter.tailscale_authkey_usw2,
    aws_s3_bucket.cache,
    aws_iam_role_policy.dns_node_cache,
  ]
}

resource "aws_instance" "dns_use2" {
  provider               = aws.use2
  ami                    = data.aws_ami.detsys_nixos_use2.id
  instance_type          = "t4g.nano"
  subnet_id              = aws_subnet.dns_use2.id
  iam_instance_profile   = aws_iam_instance_profile.dns_node.name
  key_name               = aws_key_pair.operator_use2.key_name
  vpc_security_group_ids = [aws_security_group.operator_ssh_use2.id]

  ipv6_address_count          = 1
  associate_public_ip_address = false

  metadata_options {
    http_endpoint               = "enabled"
    http_protocol_ipv6          = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    delete_on_termination = true
  }

  user_data                   = replace(local.user_data_template, "TOPLEVEL_PATH_PLACEHOLDER", var.dns_use2_toplevel_path)
  user_data_replace_on_change = true

  tags = { Name = "dns-use2" }

  depends_on = [
    aws_ssm_parameter.tailscale_authkey_use2,
    aws_s3_bucket.cache,
    aws_iam_role_policy.dns_node_cache,
  ]
}
