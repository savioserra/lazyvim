# The fonts domain: the JetBrainsMono Nerd Font tree (a checksummed pin
# with the content-probe member gate) and the fontconfig discovery the
# walker's platform coverage used to carry. Linux deploys under
# ~/.local/share/fonts; darwin under ~/Library/Fonts.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  pins = import ../../nix/lib/pins.nix { inherit lib pkgs; };

  fontTree = pins.tool "font" {
    version = "3.5.0";
    # one upstream archive serves both platform legs (same bytes, same sha)
    url = "https://github.com/ryanoasis/nerd-fonts/releases/download/v{V}/JetBrainsMono.tar.xz";
    sha256 = "0227b220360a6f819b9ead92343e8112b34733054782561af50cfba1e8afab63";
    archive = "tar.xz";
    layout = "flat";
    probe = {
      member = "JetBrainsMonoNerdFont-Regular.ttf";
      sha256 = "1767e08e6b207eb57c114e833b817e26c6a7625bbcf474e3b4dd0f73c10e5bdc";
    };
  };

  fontTarget =
    if pkgs.stdenv.isDarwin then "Library/Fonts/JetBrainsMonoNerdFont"
    else ".local/share/fonts/JetBrainsMonoNerdFont";
in
{
  config = {
    home.file.${fontTarget}.source = fontTree;

    # fc-cache picks up ~/.local/share/fonts; keep the cache fresh
    fonts.fontconfig.enable = true;
  };
}
