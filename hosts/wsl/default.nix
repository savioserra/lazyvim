# The WSL host leg: NixOS-WSL running the workstation substrate.
# Home plane: workstation-home (manifests -> HM). System plane:
# workstation-system (engine + nixpkgs toolchains). The daemon runs as a
# user unit inside the home plane. The username is the one operator knob
# on this host — flip `defaultUser` and the two user references follow.
{
  self,
  nixpkgs,
  home-manager,
  nixos-wsl,
}:
let
  system = "x86_64-linux";
  user = "savio";
in
nixpkgs.lib.nixosSystem {
  inherit system;
  specialArgs = {
    inherit self;
    engine = self.packages.${system}.workstation;
  };
  modules = [
    nixos-wsl.nixosModules.default
    ../../nix/modules/workstation-system.nix
    home-manager.nixosModules.home-manager
    (
      { engine, ... }:
      {
        workstation.enable = true;

        wsl = {
          enable = true;
          defaultUser = user;
        };
        networking.hostName = "wsl";

        home-manager = {
          useGlobalPkgs = true;
          useUserPackages = true;
          extraSpecialArgs = {
            inherit self engine;
          };
          users.${user} = import ../../nix/modules/workstation-home.nix;
        };

        system.stateVersion = "25.05";
      }
    )
  ];
}
