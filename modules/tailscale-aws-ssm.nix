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
      tailscale on AWS with EBS-persisted /var/lib/tailscale. The auth key
      is read from SSM Parameter Store on first ever boot; the node
      identity then lives on an EBS volume that follows the instance
      across replacements, so Tailscale sees one continuous device and
      the tailnet IP stays stable
    '';

    authKeyParam = lib.mkOption {
      type = lib.types.str;
      default = "/dns-nodes/tailscale-authkey";
      description = "SSM parameter (SecureString) containing the tailnet auth key used on first ever boot.";
    };

    statePathPrefix = lib.mkOption {
      type = lib.types.str;
      default = "/dns-nodes";
      description = ''
        SSM parameter prefix for the one-time state seed at
        <prefix>/<hostname>/tailscaled-state. This is consumed once on
        first boot of a fresh EBS volume (e.g., the migration from
        SSM-state to EBS-state), then becomes a no-op forever because
        the EBS-backed /var/lib/tailscale always has state.
      '';
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

    stateLabel = lib.mkOption {
      type = lib.types.str;
      default = "tsdata";
      description = ''
        ext4 filesystem label written to the EBS-attached state volume.
        The mount service formats the device with this label on first
        attach and mounts it by-label thereafter.
      '';
    };

    stateDeviceCandidates = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "/dev/nvme1n1"
        "/dev/sdf"
        "/dev/xvdf"
      ];
      description = ''
        Block device paths to probe when looking for the attached state
        volume. EBS volumes attached as /dev/sdf to Nitro instances
        typically appear as /dev/nvme1n1; non-Nitro keeps the original
        name. Probed in order; first unformatted match gets formatted.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.tailscale.enable = true;

    # Wait for the EBS state volume to attach, format it with our label on
    # first ever attach, then mount it at /var/lib/tailscale. The volume
    # is attached by terraform AFTER the instance boots, so this service
    # has to poll rather than relying on initrd / fileSystems = {}.
    systemd.services.mount-tsdata = {
      description = "Mount the EBS-attached state volume at /var/lib/tailscale";
      wantedBy = [
        "tailscaled.service"
        "tailscale-state-restore.service"
      ];
      before = [
        "tailscaled.service"
        "tailscale-state-restore.service"
      ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      unitConfig.RequiresMountsFor = "/var/lib/tailscale";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = with pkgs; [
        util-linux
        e2fsprogs
        coreutils
      ];
      script = ''
        set -euo pipefail
        MOUNT=/var/lib/tailscale
        LABEL=${cfg.stateLabel}
        mkdir -p "$MOUNT"
        if mountpoint -q "$MOUNT"; then
          echo "$MOUNT already mounted; nothing to do"
          exit 0
        fi

        DEVICE=""
        for i in $(seq 1 60); do
          if [ -b "/dev/disk/by-label/$LABEL" ]; then
            DEVICE="/dev/disk/by-label/$LABEL"
            break
          fi
          for cand in ${lib.concatStringsSep " " cfg.stateDeviceCandidates}; do
            [ -b "$cand" ] || continue
            EXISTING_LABEL=$(blkid -o value -s LABEL "$cand" 2>/dev/null || true)
            if [ "$EXISTING_LABEL" = "$LABEL" ]; then
              DEVICE="$cand"
              break 2
            fi
            # Unformatted (no blkid output at all): claim it.
            if ! blkid "$cand" >/dev/null 2>&1; then
              echo "formatting fresh EBS volume $cand with label $LABEL"
              mkfs.ext4 -L "$LABEL" "$cand"
              # let udev catch up so by-label symlink exists
              udevadm settle
              DEVICE="/dev/disk/by-label/$LABEL"
              [ -b "$DEVICE" ] || DEVICE="$cand"
              break 2
            fi
          done
          sleep 2
        done

        if [ -z "$DEVICE" ]; then
          echo "no EBS volume with label $LABEL found after polling 120s" >&2
          exit 1
        fi

        mount "$DEVICE" "$MOUNT"
        echo "mounted $DEVICE at $MOUNT"
      '';
    };

    # Seed /var/lib/tailscale from SSM if the (just-mounted) EBS volume is
    # fresh. After the first successful boot the EBS volume always has
    # state, so this exits early "already present" on every subsequent
    # boot. The SSM-state mechanism is therefore a one-shot bootstrap
    # for new volumes; we still need the parameter to exist for the
    # initial EBS migration.
    systemd.services.tailscale-state-restore = {
      description = "Seed tailscaled.state from SSM on a fresh EBS volume";
      wantedBy = [ "tailscaled.service" ];
      before = [ "tailscaled.service" ];
      after = [
        "mount-tsdata.service"
        "network-online.target"
      ];
      wants = [
        "mount-tsdata.service"
        "network-online.target"
      ];
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
          echo "tailscaled state already on EBS; not restoring"
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
            echo "no SSM seed at $PARAM; tailscale-join will mint a fresh identity"
            exit 0
          fi
          echo "ERROR fetching $PARAM: $OUT" >&2
          exit 1
        fi
        printf '%s' "$OUT" | base64 -d > "$STATE_FILE"
        chmod 600 "$STATE_FILE"
        chown root:root "$STATE_FILE"
        echo "seeded tailscaled state from $PARAM ($(wc -c < "$STATE_FILE") bytes)"
      '';
    };

    # Authenticate the daemon if it isn't already. On first ever boot (no
    # SSM seed, no EBS state) this is the only thing that creates a
    # tailnet identity. After EBS is populated, this is a steady-state
    # no-op on every boot.
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
        # tailscaled.service is Type=notify and may report ready before it
        # has finished consuming a restored state file. Reading
        # BackendState immediately can give Starting/NoState and cause us
        # to authkey-join unnecessarily — which then trips Tailscale's
        # anti-clone heuristic. Wait for the daemon to make up its mind.
        for i in 1 2 3 4 5 6 7 8 9 10; do
          STATE=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "Unknown"')
          case "$STATE" in
            Running)
              echo "tailscale already Running (attempt $i); nothing to do"
              exit 0
              ;;
            NoState|NeedsLogin)
              echo "tailscale BackendState=$STATE; authkey-join needed"
              break
              ;;
            *)
              echo "tailscale BackendState=$STATE; waiting..."
              sleep 2
              ;;
          esac
        done
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

    # Block until tailscaled reports BackendState=Running. Once this
    # exits cleanly the tailscale-settled.target activates and dependent
    # units (CoreDNS, anything that needs the tailnet) get to run.
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
  };
}
