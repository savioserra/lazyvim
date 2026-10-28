# The fonts domain: the JetBrainsMono Nerd Font (nixpkgs, via the
# foundation overlay) and fontconfig discovery. Files deploy at the
# per-platform targets: linux ~/.local/share/fonts, darwin
# ~/Library/Fonts.
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
