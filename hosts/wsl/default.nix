# The WSL host leg: NixOS-WSL running the workstation substrate.
# Home plane: workstation-home (the native declarations -> HM). System plane:
# workstation-system (the nixpkgs toolchains + the transport wiring).
#
# This file is the ONLY place this host's identity lives — the flake
# derives the homeConfigurations rebuild key and every username/home path
# from the block below (the identity gate in check.sh reds on personal
# strings anywhere else under nix/ hosts/ flake.nix). Flip `user` and the
# NixOS user, the HM user and the rebuild key all follow.
{
  self,
  nixpkgs,
  home-manager,
  nixos-wsl,
}:
let
  system = "x86_64-linux";

  # --- host identity (the single source) ------------------------------------
  # The live WSL operator user (operator report 2026-10-21). The real-host
  # cutover owns proving these values against the live host before first
  # switch.
  user = "shyylol";
  homeDir = "/home/${user}";
  homeKey = "${user}@wsl";
in
{
  # identity surface the flake consumes — derive, never hand-type
  inherit system user homeDir homeKey;

  nixosConfig = nixpkgs.lib.nixosSystem {
    inherit system;
    specialArgs = {
      inherit self;
    };
    modules = [
      nixos-wsl.nixosModules.default
      ../../nix/modules/workstation-system.nix
      ../../nix/modules/host.nix
      home-manager.nixosModules.home-manager
      (
        { config, ... }:
        {
          workstation.enable = true;

          # the foundation domain's pin surface (harlequin + hsql)
          nixpkgs.overlays = [ self.overlays.default ];

          # host identity: the ONLY place this host's facts are written
          # (the options are declared in the substrate; consumers derive)
          workstation.host = {
            name = "wsl";
            user = user;
            homeDirectory = homeDir;
            # tailscale.fqdn: the operator declares the host's MagicDNS
            # name here at first real apply
          };
          # the fleet transport (the shared system module owns the wiring)
          workstation.foundation.tailscale.enable = true;

          wsl = {
            enable = true;
            defaultUser = user;
          };
          # the canonical declaration derives from the identity option —
          # never a second literal
          networking.hostName = config.workstation.host.name;

          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = true;
            extraSpecialArgs = {
              inherit self;
            };
            users.${user}.imports = [
              (
                { ... }:
                {
                  # the switch driver's default targets: this host's flake
                  # attrs, derived from the identity block (never hand-typed)
                  workstation.switch.homeAttr = homeKey;
                  workstation.switch.systemAttr = "wsl";
                }
              )
              ../../nix/modules/workstation-home.nix
            ];
          };

          system.stateVersion = "25.05";
        }
      )
    ];
  };
}
