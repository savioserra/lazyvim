# The mac leg: nix-darwin plus the machine's home plane through
# home-manager. Brew keeps casks only; a formula retired from brew must be
# in the nix set below.
{
  nixpkgs,
  home-manager,
  nix-darwin,
  machine,
}:
let
  system = "aarch64-darwin";
  hostPkgs = nixpkgs.legacyPackages.${system};

  nixPackages = [
    hostPkgs.eza
    hostPkgs.tmux
    hostPkgs.btop
  ];

  owns =
    name:
    builtins.any (
      p:
      let
        pname = p.pname or null;
        n = p.name or "";
      in
      pname == name || n == name || nixpkgs.lib.hasPrefix "${name}-" n
    ) nixPackages;

  assertions = map (name: {
    assertion = owns name;
    message = "workstation-nix: retired brew formula '${name}' is not in the darwin nix set — add it before retiring it from brew";
  }) (import ./brew.nix);
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

          environment.systemPackages = nixPackages;

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

          inherit assertions;

          system.stateVersion = 5;
        }
      )
    ];
  };
}
