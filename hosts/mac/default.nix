# The mac leg: nix-darwin plus the machine's home plane through
# home-manager.
{
  nixpkgs,
  home-manager,
  nix-darwin,
  machine,
}:
let
  system = "aarch64-darwin";
in
{
  inherit system;

  darwinConfig = nix-darwin.lib.darwinSystem {
    inherit system;
    modules = [
      ../../nix/modules/workstation-system.nix
      ../../nix/modules/host.nix
      home-manager.darwinModules.home-manager
      (
        { config, lib, ... }:
        {
          nixpkgs.hostPlatform = system;
          nix.enable = false;
          nixpkgs.config.allowUnfreePredicate = import ../../nix/lib/license.nix { inherit lib; };

          workstation.host = {
            name = machine.host;
            inherit (machine) user;
            homeDirectory = machine.home;
          };
          workstation.enable = true;
          workstation.network.tailscale.enable = machine.networkEnable;
          networking.hostName = config.workstation.host.name;
          users.users.${machine.user}.home = machine.home;
          system.primaryUser = machine.user;

          homebrew = {
            enable = true;
            onActivation = {
              autoUpdate = true;
              upgrade = true;
            };
            brews = [ ];
            casks = [ ];
          };

          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = true;
            backupFileExtension = "pre-nix-darwin";
            users.${machine.user}.imports = machine.homeModules ++ [
              { workstation.switch.systemAttr = machine.key; }
              ../../nix/modules/workstation-home.nix
            ];
          };

          system.stateVersion = 5;
        }
      )
    ];
  };
}
