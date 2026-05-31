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
  options.cloud.dnsNode = {
    zone = lib.mkOption {
      type = lib.types.str;
      default = "ts.t11s.net";
      description = "DNS zone served by this node.";
    };

    tailscaleAuthKeyParam = lib.mkOption {
      type = lib.types.str;
      default = "/dns-nodes/tailscale-authkey";
      description = "SSM Parameter Store path containing the tailscale auth key (SecureString).";
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

    # The S3 substituter for the operator-managed closure cache.
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
    # cloud-init from the aws_key_pair declared in terraform — we just need
    # the daemon. Tailscale SSH covers normal access once the node joins.
    services.openssh.enable = true;

    services.tailscale.enable = true;

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

    networking.firewall.interfaces.tailscale0 = {
      allowedUDPPorts = [ 53 ];
      allowedTCPPorts = [ 53 ];
    };

    systemd.services.tailscale-bootstrap = {
      description = "Join tailnet using auth key from SSM Parameter Store";
      wantedBy = [ "multi-user.target" ];
      after = [
        "tailscaled.service"
        "network-online.target"
      ];
      wants = [
        "tailscaled.service"
        "network-online.target"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "5s";
      };
      # The default SSM endpoint (ssm.<region>.amazonaws.com) is IPv4-only;
      # the dual-stack endpoint (ssm.<region>.api.aws) has AAAA records.
      # AWS_USE_DUALSTACK_ENDPOINT=true makes awscli rewrite the URL.
      environment.AWS_USE_DUALSTACK_ENDPOINT = "true";
      path = [
        pkgs.awscli2
        pkgs.tailscale
      ];
      script = ''
        set -euo pipefail
        if tailscale status --json 2>/dev/null | ${pkgs.jq}/bin/jq -e '.BackendState == "Running"' >/dev/null; then
          echo "tailscale already running; nothing to do"
          exit 0
        fi
        AUTH_KEY=$(aws ssm get-parameter \
          --name ${cfg.tailscaleAuthKeyParam} \
          --with-decryption \
          --query 'Parameter.Value' --output text)
        if [ -z "$AUTH_KEY" ] || [ "$AUTH_KEY" = "None" ]; then
          echo "ERROR: SSM parameter returned empty or null auth key" >&2
          exit 1
        fi
        tailscale up \
          --authkey "$AUTH_KEY" \
          --hostname "${config.networking.hostName}" \
          --advertise-tags=tag:dns-node \
          --ssh
      '';
    };

    # Ensure CoreDNS waits for tailscale0 to exist (the bind directive
    # requires the interface to be up).
    systemd.services.coredns = {
      after = [ "tailscale-bootstrap.service" ];
      wants = [ "tailscale-bootstrap.service" ];
    };
  };
}
