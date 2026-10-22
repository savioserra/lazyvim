# The omarchy host leg: Arch + Hyprland running the substrate through
# STANDALONE home-manager — nix stages everything, omarchy's systemd runs
# the daemon user unit. No NixOS flip: the Arch hosts' NixOS migration is
# deferred by operator ruling (2026-10-21).
#
# This file is the ONLY place this host's identity lives — the flake
# derives the homeConfigurations rebuild key and every username/home path
# from the block below (the identity gate in check.sh reds on personal
# strings anywhere else under nix/ hosts/ flake.nix). Flip `user` and the
# HM user and the rebuild key all follow; the real-host cutover owns
# proving them against the live host before first switch.
{
  self,
  nixpkgs,
  home-manager,
}:
let
  system = "x86_64-linux";

  # --- host identity (the single source) ------------------------------------
  # Placeholder until the host's first apply: the operator flips this one
  # line to the omarchy session's real user (the eval carries no personal
  # identity by law).
  user = "omarchy";
  homeDir = "/home/${user}";
  homeKey = "${user}@omarchy";
in
{
  # identity surface the flake consumes — derive, never hand-type
  inherit system user homeDir homeKey;

  homeConfig = home-manager.lib.homeManagerConfiguration {
    pkgs = nixpkgs.legacyPackages.${system};
    extraSpecialArgs = {
      inherit self;
      engine = self.packages.${system}.workstation;
    };
    modules = [
      (
        { ... }:
        {
          home.username = user;
          home.homeDirectory = homeDir;
          # the switch driver's default home-plane target: this leg's flake
          # attr, derived (never hand-typed)
          workstation.switch.homeAttr = homeKey;
        }
      )
      ../../nix/modules/workstation-home.nix
      ./home.nix
    ];
  };
}
