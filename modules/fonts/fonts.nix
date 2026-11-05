# The fonts domain: the JetBrainsMono Nerd Font and fontconfig discovery.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  fontPackage = pkgs.nerd-fonts.jetbrains-mono;

  fontTree = "${fontPackage}/share/fonts/truetype/NerdFonts/JetBrainsMono";

  fontTarget =
    if pkgs.stdenv.hostPlatform.isDarwin then
      "Library/Fonts/JetBrainsMonoNerdFont"
    else
      ".local/share/fonts/JetBrainsMonoNerdFont";
in
{
  options.workstation.fonts.enable = lib.mkEnableOption "the JetBrainsMono Nerd Font" // {
    default = true;
  };

  config = lib.mkIf config.workstation.fonts.enable {
    home.file.${fontTarget}.source = fontTree;

    fonts.fontconfig.enable = true;
  };
}
