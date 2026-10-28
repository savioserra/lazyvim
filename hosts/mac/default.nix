# The mac leg: the substrate via nix-darwin (home-manager integrated).
#
# Brew keeps ONLY casks (GUI apps). Every formula retired from brew must
# exist in the nix set below or the eval FAILS (the assertions gate) —
# retiring a formula before nix owns it is an eval-time error, never a
# broken host discovered later. Consumer smoke on the mac host is the
# exit proof, not this eval (the operator runs
# `darwin-rebuild switch --flake .#<hostKey>` there).
#
# Identity is NOT in this file — hosts/identity.nix holds it (captured
# by `workstation init` at install time; the committed copy is the
# template). The flake derives the darwinConfigurations key and every
# username/home path from that file.
{
  self,
  nixpkgs,
  home-manager,
  nix-darwin,
}:
let
  system = "aarch64-darwin";

  # --- host identity --------------------------------------------------------
  # NOT here. hosts/identity.nix holds the machine's identity, captured
  # once by `workstation init` at install time (the local rewrite stays
  # uncommitted; the committed copy is the template). This file is the
  # mac leg TEMPLATE — flip nothing by hand.
  id = import ../identity.nix;
  user = id.user;
  hostName = id.host;
  homeDir = id.home;
  hostKey = "${user}@${hostName}";

  retiredBrew = import ./retired-brew.nix;

  # The nix set this host's CLI lives on: the nixpkgs toolchains the
  # substrate owns (mirrors the system leg's toolchain replacements; the
  # mac's own brew formulas retire into this list).
  # eza leads it because the walker REFUSED eza's download envelope on
  # darwin_arm64 (no pinned asset) — the nix set must own it.
  nixPackages =
    let
      hostPkgs = nixpkgs.legacyPackages.${system};
    in
    [
      hostPkgs.eza
      hostPkgs.tmux
      hostPkgs.btop
    ];

  # nix owns `name` when some package's pname equals it, or its store name
  # is the formula name possibly version-suffixed (name / name-<version>).
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
  }) retiredBrew;
in
{
  # identity surface the flake consumes — derive, never hand-type
  inherit
    system
    user
    hostName
    homeDir
    hostKey
    ;

  darwinConfig = nix-darwin.lib.darwinSystem {
    inherit system;
    specialArgs = {
      inherit self;
    };
    modules = [
      ../../nix/modules/workstation-system.nix
      ../../nix/modules/host.nix
      home-manager.darwinModules.home-manager
      (
        { config, ... }:
        {
          nixpkgs.hostPlatform = system;
          # the mac's nix is Determinate-managed: nix-darwin's native Nix
          # management conflicts with the Determinate daemon (the switch
          # fails without this) — nix.* options stay unused on this leg
          nix.enable = false;
          # the foundation domain's pin surface (harlequin + hsql)
          nixpkgs.overlays = [ self.overlays.default ];
          # the secrets domain's license acceptance (the 1Password CLI rides
          # nixpkgs unfree — nix/lib/license.nix, named and scoped)
          nixpkgs.config.allowUnfreePredicate = import ../../nix/lib/license.nix { lib = nixpkgs.lib; };

          # host identity: the ONLY place this host's facts are written
          # (the options are declared in the substrate; consumers derive)
          workstation.host = {
            name = hostName;
            user = user;
            homeDirectory = homeDir;
          };
          # the fleet transport (the shared system module owns the wiring)
          workstation.network.tailscale.enable = true;
          # the canonical declaration derives from the identity option —
          # never a second literal
          networking.hostName = config.workstation.host.name;
          users.users.${user}.home = homeDir;
          # nix-darwin 25.05's multi-user migration gate
          system.primaryUser = user;

          environment.systemPackages = nixPackages;

          # brew keeps ONLY casks — GUI apps stay in brew, every CLI formula
          # retires into the nix set above.
          homebrew = {
            enable = true;
            onActivation = {
              autoUpdate = true;
              upgrade = true;
              # cleanup dropped: brew 7.0.11 disabled the --cleanup switch
              # entirely (the cutover caught it)
            };
            brews = [ ];
            casks = [
              # the GUI set lives here (operator-maintained on the mac host;
              # the enumeration ride is hosts/mac/README.md)
            ];
          };

          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = true;
            # first switches on an old-engine home: the conflicting
            # deployed files back up instead of aborting
            backupFileExtension = "pre-nix-darwin";
            extraSpecialArgs = {
              inherit self;
            };
            users.${user}.imports = [
              (
                { ... }:
                {
                  home.username = user;
                  home.homeDirectory = homeDir;
                  # the operator's shell extras: the identity file is the
                  # per-machine declaration point (shellExtras, optional)
                  workstation.foundation.shell.extras = id.shellExtras or "";
                  # the mac's mutating seam is the --system plane
                  # (darwin-rebuild); the driver's default system target is
                  # derived from the identity block (never hand-typed).
                  # homeAttr stays unset — the staged driver fails closed
                  # naming the fix when the default-verb home plane is
                  # used (set workstation.switch.homeAttr here to opt in)
                  workstation.switch.systemAttr = hostKey;
                }
              )
              # this machine's capability selection (hosts/selections.nix)
              (
                (import ../../nix/lib/selections.nix {
                  lib = nixpkgs.lib;
                  treeRoot = ../..;
                }).translationModule
                  ../../hosts/selections.nix
              )
              ../../nix/modules/workstation-home.nix
            ];
          };

          # The assertion wiring runs through the system's assertions gate:
          # eval fails with every violated entry named.
          inherit assertions;

          system.stateVersion = 5;
        }
      )
    ];
  };

}
