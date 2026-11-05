# The go member: the toolchain and its editor profile entry.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.workstation.languages.go;
  go = pkgs.go;
in
{
  options.workstation.languages.go.enable =
    lib.mkEnableOption "the go toolchain and its editor profile";

  config = lib.mkIf (config.workstation.languages.enable && cfg.enable) {
    home.packages = [ go ];

    workstation.editor = lib.mkIf config.workstation.editor.enable {
      languages = [
        {
          id = "go";
          requires = [ "go" ];
          lazyvim_extras = [ "lazyvim.plugins.extras.lang.go" ];
          plugin_module = "languages.plugins.go";
        }
      ];

      languagePlugins = [
        ./files/languages/plugins/go.lua
      ];
    };
  };
}
