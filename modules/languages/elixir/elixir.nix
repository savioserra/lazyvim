# The elixir member: the beam toolchain and its editor profile entry.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.workstation.languages.elixir;
in
{
  options.workstation.languages.elixir.enable =
    lib.mkEnableOption "the elixir toolchain and its editor profile";

  config = lib.mkIf (config.workstation.languages.enable && cfg.enable) {
    home.packages = [ pkgs.beam.packages.erlang_28.elixir ];

    workstation.editor = lib.mkIf config.workstation.editor.enable {
      languages = [
        {
          id = "elixir";
          lazyvim_extras = [ "lazyvim.plugins.extras.lang.elixir" ];
          mason_packages = [ "elixir-ls" ];
          plugin_module = "languages.plugins.elixir";
        }
      ];

      languagePlugins = [
        ./files/languages/plugins/elixir.lua
      ];
    };
  };
}
