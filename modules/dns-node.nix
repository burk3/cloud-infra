{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cloud.dnsNode;
in
{
  imports = [ ./tailscale-aws-ssm.nix ];

  options.cloud.dnsNode = {
    zone = lib.mkOption {
      type = lib.types.str;
      default = "ts.t11s.net";
      description = "DNS zone served by this node.";
    };

    cacheUrl = lib.mkOption {
      type = lib.types.str;
      default = "s3://burk3-dns-cache?region=us-west-2&endpoint=s3.dualstack.us-west-2.amazonaws.com";
      description = ''
        S3 binary cache URL where the operator pushes signed closures. The
        instance role grants `s3:GetObject` on the bucket; signatures are
        verified against `cachePublicKey`. Uses the dual-stack endpoint so
        IPv6-only instances can reach it.
      '';
    };

    cachePublicKey = lib.mkOption {
      type = lib.types.str;
      default = "burk3-dns-cache:ZAWST40z9ARFmzxrLHyLHKzqpD+FzM7hxkCkPbrc4Bs=";
      description = "Public half of the signing keypair used to verify closures from `cacheUrl`.";
    };
  };

  config = {
    time.timeZone = "UTC";

    nix.settings.extra-substituters = [ cfg.cacheUrl ];
    nix.settings.trusted-public-keys = [ cfg.cachePublicKey ];

    # systemd-resolved's default fallback is Cloudflare (1.0.0.1) over IPv4,
    # which is unreachable on our IPv6-only public network. Point at the AWS
    # VPC resolver (link-local, reachable from inside the VPC).
    networking.nameservers = [
      "fd00:ec2::253"
      "169.254.169.253"
    ];

    # Break-glass SSH (pre-tailscale). AWS injects the operator pubkey via
    # cloud-init from the aws_key_pair declared in terraform.
    services.openssh.enable = true;

    cloud.tailscaleAwsSsm = {
      enable = true;
      tags = [ "tag:dns-node" ];
    };

    services.coredns = {
      enable = true;
      config = ''
        ${cfg.zone} {
          bind tailscale0
          forward . 169.254.169.253 fd00:ec2::253
          cache 60
          log
          errors
        }
      '';
    };

    # bind tailscale0 in the corefile requires the interface to exist and
    # be authenticated. tailscale-settled.target fires once tailscaled is
    # Running, which is exactly when tailscale0 is usable.
    systemd.services.coredns = {
      after = [ "tailscale-settled.target" ];
      wants = [ "tailscale-settled.target" ];
    };

    networking.firewall.interfaces.tailscale0 = {
      allowedUDPPorts = [ 53 ];
      allowedTCPPorts = [ 53 ];
    };
  };
}
