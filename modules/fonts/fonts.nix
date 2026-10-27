# The fonts domain: the JetBrainsMono Nerd Font from nixpkgs (operator
# ruling 2026-10-27: the pins machinery is redundant — the package rides
# the foundation domain's pin-override overlay, current with the retired
# 3.5.0 download pin) and the fontconfig discovery. The font FILES deploy
# at the same per-platform targets the pin tree used (linux:
# ~/.local/share/fonts; darwin: ~/Library/Fonts) — the claim reaches into
# the package's fontconfig-visible tree.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  fontPackage = pkgs.nerd-fonts.jetbrains-mono;

  # the package's font directory (the nerd-fonts packages install under
  # share/fonts/truetype/NerdFonts/<font>)
  fontTree = "${fontPackage}/share/fonts/truetype/NerdFonts/JetBrainsMono";

  fontTarget =
    if pkgs.stdenv.isDarwin then
      "Library/Fonts/JetBrainsMonoNerdFont"
    else
      ".local/share/fonts/JetBrainsMonoNerdFont";
in
{
  # the selection gate (workstation.fonts.enable, nix/lib/selections.nix):
  # disabled = the definitions skip, never the files
  config = lib.mkIf config.workstation.fonts.enable {
    home.file.${fontTarget}.source = fontTree;

    # fc-cache picks up ~/.local/share/fonts; keep the cache fresh
    fonts.fontconfig.enable = true;
  };
}
