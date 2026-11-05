# The mac leg: nix-darwin, Homebrew pinned by nix-homebrew, and the
# machine's home plane through home-manager.
{
  nixpkgs,
  home-manager,
  nix-darwin,
  nix-homebrew,
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
      nix-homebrew.darwinModules.nix-homebrew
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

          nix-homebrew = {
            enable = true;
            inherit (machine) user;
            autoMigrate = true;
          };
          homebrew.enable = true;

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
