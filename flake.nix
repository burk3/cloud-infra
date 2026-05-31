{
  description = "AWS DNS-node infrastructure for ts.t11s.net";

  inputs.nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0";

  outputs =
    { self, nixpkgs }:
    let
      mkDnsNode =
        hostName:
        nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            "${nixpkgs}/nixos/modules/virtualisation/amazon-image.nix"
            ./modules/dns-node.nix
            {
              networking.hostName = hostName;
              system.stateVersion = "25.11";
            }
          ];
        };

      forSystem =
        system: f:
        f {
          inherit system;
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
        };
    in
    {
      nixosConfigurations = {
        dns-usw2 = mkDnsNode "dns-usw2";
        dns-use2 = mkDnsNode "dns-use2";
      };

      devShells.x86_64-linux.default = forSystem "x86_64-linux" (
        { pkgs, ... }:
        pkgs.mkShellNoCC {
          packages = with pkgs; [
            terraform
            awscli2
            jq
          ];
        }
      );

      formatter.x86_64-linux = forSystem "x86_64-linux" ({ pkgs, ... }: pkgs.nixfmt-rfc-style);
    };
}
