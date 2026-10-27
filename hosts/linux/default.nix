# The linux leg TEMPLATE: NixOS-WSL-flavored system plane + the home plane
# (workstation-home, the native declarations -> HM). Identity is NOT here —
# hosts/identity.nix holds it, captured by `workstation init` at install
# time (the committed copy is the template; the local rewrite stays
# uncommitted). The flake derives the rebuild key and every username/home
# path from that file.
{
  self,
  nixpkgs,
  home-manager,
  nixos-wsl,
}:
let
  system = "x86_64-linux";

  # --- host identity --------------------------------------------------------
  # NOT here. hosts/identity.nix holds the machine's identity, captured
  # once by `workstation init` at install time (the local rewrite stays
  # uncommitted; the committed copy is the template). This file is the
  # linux leg TEMPLATE — flip nothing by hand.
  id = import ../identity.nix;
  user = id.user;
  homeDir = id.home;
  homeKey = "${user}@${id.host}";
in
{
  # identity surface the flake consumes — derive, never hand-type
  inherit
    system
    user
    homeDir
    homeKey
    ;
  name = id.host;

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
        { config, lib, ... }:
        {
          workstation.enable = true;

          # the foundation domain's pin surface (harlequin + hsql)
          nixpkgs.overlays = [ self.overlays.default ];
          # the secrets domain's license acceptance (the 1Password CLI rides
          # nixpkgs unfree — nix/lib/license.nix, named and scoped)
          nixpkgs.config.allowUnfreePredicate = import ../../nix/lib/license.nix { inherit lib; };

          # host identity: the ONLY place this host's facts are written
          # (the options are declared in the substrate; consumers derive)
          workstation.host = {
            name = id.host;
            user = user;
            homeDirectory = homeDir;
          }
          // (lib.optionalAttrs ((id.tailscaleFqdn or "") != "") {
            tailscale.fqdn = id.tailscaleFqdn;
          });
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
                  workstation.switch.systemAttr = id.host;
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
