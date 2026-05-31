{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cloud.tailscaleAwsSsm;
in
{
  options.cloud.tailscaleAwsSsm = {
    enable = lib.mkEnableOption ''
      tailscale on AWS with SSM-backed identity persistence. State stored at
      <statePathPrefix>/<hostname>/tailscaled-state so a recreated instance
      with the same hostname rejoins the tailnet with the same node key
      (and therefore the same IP)
    '';

    authKeyParam = lib.mkOption {
      type = lib.types.str;
      default = "/dns-nodes/tailscale-authkey";
      description = "SSM parameter (SecureString) containing the tailnet auth key used on first ever boot.";
    };

    statePathPrefix = lib.mkOption {
      type = lib.types.str;
      default = "/dns-nodes";
      description = "SSM parameter prefix. Each host stores its base64-encoded tailscaled.state at <prefix>/<hostname>/tailscaled-state.";
    };

    tags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "tag:dns-node" ];
      description = "Tailscale ACL tags advertised on join.";
    };

    enableSsh = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Tailscale-managed SSH (--ssh) on join.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.tailscale.enable = true;

    # Restore tailscaled.state from SSM before tailscaled starts. On a fresh
    # instance (empty /var/lib/tailscale) this transplants the previous
    # host's node identity. On a box that already has state on disk this is
    # a no-op.
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
            echo "no saved state at $PARAM; tailscale-join will mint a fresh identity"
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

    # Authenticate the daemon if it isn't already. On first ever boot (no
    # SSM state, no local state) this is the only thing that creates a
    # tailnet identity for this host. On a restored box it's a no-op.
    systemd.services.tailscale-join = {
      description = "Authenticate tailscaled to the tailnet (no-op if already Running)";
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
      environment.AWS_USE_DUALSTACK_ENDPOINT = "true";
      path = [
        pkgs.awscli2
        pkgs.tailscale
        pkgs.jq
      ];
      script = ''
        set -euo pipefail
        if tailscale status --json 2>/dev/null | jq -e '.BackendState == "Running"' >/dev/null; then
          echo "tailscale already Running; nothing to do"
          exit 0
        fi
        AUTH_KEY=$(aws ssm get-parameter \
          --name ${cfg.authKeyParam} \
          --with-decryption \
          --query 'Parameter.Value' --output text)
        if [ -z "$AUTH_KEY" ] || [ "$AUTH_KEY" = "None" ]; then
          echo "ERROR: SSM parameter returned empty or null auth key" >&2
          exit 1
        fi
        tailscale up \
          --authkey "$AUTH_KEY" \
          --hostname "${config.networking.hostName}" \
          ${lib.optionalString (cfg.tags != [ ]) "--advertise-tags=${lib.concatStringsSep "," cfg.tags}"} \
          ${lib.optionalString cfg.enableSsh "--ssh"}
      '';
    };

    # Block until tailscaled reports BackendState=Running. Once this exits
    # cleanly, the tailscale-settled.target activates and dependent units
    # (state-save, coredns, anything that needs the tailnet up) get to run.
    systemd.services.tailscale-wait-settled = {
      description = "Block until tailscaled reaches Running";
      after = [ "tailscale-join.service" ];
      wants = [ "tailscale-join.service" ];
      requiredBy = [ "tailscale-settled.target" ];
      before = [ "tailscale-settled.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [
        pkgs.tailscale
        pkgs.jq
      ];
      script = ''
        set -uo pipefail
        for i in $(seq 1 60); do
          STATE=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "Unknown"')
          if [ "$STATE" = "Running" ]; then
            echo "tailscale BackendState=Running after $i attempt(s)"
            exit 0
          fi
          echo "tailscale BackendState=$STATE; waiting..."
          sleep 2
        done
        echo "tailscale never reached Running within 120s" >&2
        exit 1
      '';
    };

    systemd.targets.tailscale-settled = {
      description = "Tailscale daemon connected to the tailnet";
      wantedBy = [ "multi-user.target" ];
    };

    # Push current tailscaled.state to SSM so future instances with this
    # hostname can restore it. Runs once per boot after the tailnet
    # connection is up. By that point IMDS is reliably reachable, which
    # also dodges the early-boot NoRegion race awscli2 hits otherwise.
    systemd.services.tailscale-state-save = {
      description = "Save tailscaled.state to SSM after tailnet is up";
      wantedBy = [ "tailscale-settled.target" ];
      after = [ "tailscale-settled.target" ];
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
        set -euo pipefail
        STATE_FILE=/var/lib/tailscale/tailscaled.state
        if [ ! -s "$STATE_FILE" ]; then
          echo "no tailscaled.state to save (this should be unreachable post-settled)" >&2
          exit 1
        fi
        STATE_B64=$(base64 -w0 "$STATE_FILE")
        aws ssm put-parameter \
          --name "${cfg.statePathPrefix}/${config.networking.hostName}/tailscaled-state" \
          --type SecureString \
          --value "$STATE_B64" \
          --overwrite >/dev/null
        echo "saved tailscaled state to SSM"
      '';
    };
  };
}
