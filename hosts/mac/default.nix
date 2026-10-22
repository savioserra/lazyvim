# The mac leg: the substrate via nix-darwin (home-manager integrated).
#
# Brew keeps ONLY casks (GUI apps). Every formula retired from brew must
# exist in the nix set below or the eval FAILS (the assertions gate) —
# retiring a formula before nix owns it is an eval-time error, never a
# broken host discovered later. Consumer smoke on the mac host is the
# exit proof, not this eval (the operator runs
# `darwin-rebuild switch --flake .#<hostKey>` there).
#
# This file is the ONLY place this host's identity lives — the flake
# derives the darwinConfigurations key and every username/home path from
# the block below (the identity gate in check.sh reds on personal strings
# anywhere else under nix/ hosts/ flake.nix). Flip `user`/`hostName` and
# the darwin user, the HM user and the rebuild key all follow; the
# real-host cutover owns proving them against the live host before first
# switch.
#
# The engine on aarch64-darwin evals clean (the named gap: per-target NIF
# vendoring is open) — the darwin leg consumes the real engine derivation
# exactly like the Linux legs, and the first real switch must BUILD it on
# the mac.
{
  self,
  nixpkgs,
  home-manager,
  nix-darwin,
}:
let
  system = "aarch64-darwin";

  # --- host identity (the single source) ------------------------------------
  # Placeholder until the host's first apply: the operator flips these two
  # lines to the mac's real user and hostname (the eval carries no
  # personal identity by law).
  user = "mac";
  hostName = "mac";
  homeDir = "/Users/${user}";
  hostKey = "${user}@${hostName}";

  retiredBrew = import ./retired-brew.nix;

  # The nix set this host's CLI lives on: the engine plus the nixpkgs
  # toolchains the substrate owns (mirrors the system leg's toolchain
  # replacements; the mac's own brew formulas retire into this list).
  # eza leads it because the walker REFUSES eza's download envelope on
  # darwin_arm64 (no pinned asset) — the nix set must own it or the
  # opt-link lane refuses the link as dangling.
  nixPackages = with nixpkgs.legacyPackages.${system}; [
    self.packages.${system}.workstation
    eza
    tmux
    btop
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
  inherit system user hostName homeDir hostKey;

  darwinConfig = nix-darwin.lib.darwinSystem {
    inherit system;
    specialArgs = {
      inherit self;
      engine = self.packages.${system}.workstation;
    };
    modules = [
      home-manager.darwinModules.home-manager
      (
        { config, ... }:
        {
          nixpkgs.hostPlatform = system;

          networking.hostName = hostName;
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
              cleanup = "zap";
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
            extraSpecialArgs = {
              inherit self;
              engine = self.packages.${system}.workstation;
            };
            users.${user}.imports = [
              (
                { ... }:
                {
                  home.username = user;
                  home.homeDirectory = homeDir;
                  # the mac's mutating seam is the --system plane
                  # (darwin-rebuild); the driver's default system target is
                  # derived from the identity block (never hand-typed)
                  workstation.switch.systemAttr = hostKey;
                }
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
