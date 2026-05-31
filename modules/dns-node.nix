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

    statePathPrefix = lib.mkOption {
      type = lib.types.str;
      default = "/dns-nodes";
      description = ''
        SSM Parameter Store path prefix for per-host persistent state. Each
        host stores its tailscaled.state (base64-encoded SecureString) at
        `<statePathPrefix>/<hostname>/tailscaled-state`. The restore service
        pulls this at boot so a recreated instance with the same hostname
        keeps the same tailnet node identity (and therefore the same IP).
      '';
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

    # Restore tailscaled.state from SSM before tailscaled starts. On a fresh
    # instance (empty /var/lib/tailscale), this transplants the node identity
    # of the previous host with this hostname, so the box rejoins with the
    # same tailnet IP. On an already-bootstrapped box, this is a no-op
    # (existing state file wins).
    systemd.services.tailscale-state-restore = {
      description = "Restore tailscaled.state from SSM (preserve tailnet identity across recreates)";
      wantedBy = [ "tailscaled.service" ];
      before = [ "tailscaled.service" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      environment.AWS_USE_DUALSTACK_ENDPOINT = "true";
      path = [
        pkgs.awscli2
        pkgs.coreutils
      ];
      script = ''
        set -uo pipefail
        STATE_FILE=/var/lib/tailscale/tailscaled.state
        if [ -s "$STATE_FILE" ]; then
          echo "local tailscaled state already present; not restoring"
          exit 0
        fi
        PARAM="${cfg.statePathPrefix}/${config.networking.hostName}/tailscaled-state"
        OUT=$(aws ssm get-parameter \
                --name "$PARAM" \
                --with-decryption \
                --query 'Parameter.Value' \
                --output text 2>&1)
        rc=$?
        if [ "$rc" -ne 0 ]; then
          if echo "$OUT" | grep -q ParameterNotFound; then
            echo "no saved state at $PARAM; tailscale-bootstrap will mint a fresh identity"
            exit 0
          fi
          echo "ERROR fetching $PARAM: $OUT" >&2
          exit 1
        fi
        mkdir -p /var/lib/tailscale
        printf '%s' "$OUT" | base64 -d > "$STATE_FILE"
        chmod 600 "$STATE_FILE"
        chown root:root "$STATE_FILE"
        echo "restored tailscaled state from $PARAM ($(wc -c < "$STATE_FILE") bytes)"
      '';
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
        pkgs.coreutils
      ];
      script = ''
        set -euo pipefail
        if tailscale status --json 2>/dev/null | ${pkgs.jq}/bin/jq -e '.BackendState == "Running"' >/dev/null; then
          echo "tailscale already running; not re-authing"
        else
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
        fi
        STATE_FILE=/var/lib/tailscale/tailscaled.state
        if [ -s "$STATE_FILE" ]; then
          STATE_B64=$(base64 -w0 "$STATE_FILE")
          aws ssm put-parameter \
            --name "${cfg.statePathPrefix}/${config.networking.hostName}/tailscaled-state" \
            --type SecureString \
            --value "$STATE_B64" \
            --overwrite >/dev/null
          echo "saved tailscaled state to SSM"
        fi
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
