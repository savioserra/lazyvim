# The linux system leg (NixOS-WSL): the system plane plus the machine's
# home plane through home-manager.
{
  self,
  nixpkgs,
  home-manager,
  nixos-wsl,
  machine,
}:
{
  nixosConfig = nixpkgs.lib.nixosSystem {
    inherit (machine) system;
    specialArgs = {
      inherit self;
    };
    modules = [
      nixos-wsl.nixosModules.default
      ../../nix/modules/workstation-system.nix
      ../../nix/modules/host.nix
      home-manager.nixosModules.home-manager
      (
        { config, lib, ... }:
        {
          workstation.enable = true;
          nixpkgs.config.allowUnfreePredicate = import ../../nix/lib/license.nix { inherit lib; };

          workstation.host = {
            name = machine.host;
            inherit (machine) user;
            homeDirectory = machine.home;
          };
          workstation.network.tailscale.enable = machine.networkEnable;

          wsl = {
            enable = true;
            defaultUser = lib.mkIf (machine.user != "root") machine.user;
          };
          networking.hostName = config.workstation.host.name;

          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = true;
            extraSpecialArgs = {
              inherit self;
            };
            users.${machine.user}.imports = machine.homeModules ++ [
              {
                workstation.switch.homeAttr = machine.key;
                workstation.switch.systemAttr = machine.host;
              }
              ../../nix/modules/workstation-home.nix
            ];
          };

          system.stateVersion = "25.05";
        }
      )
    ];
  };
}
