# The Elixir language capability: the nixpkgs beam toolchain (the mise
# lane's native replacement — the same OTP the engine release builds on)
# and the editor profile entry with its payload plugin module. The
# behavior cases died with the manifest (the editor domain's precedent:
# they fed the walker's verify lane, never the deployed file).
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
{
  config = {
    # the toolchain: elixir 1.18.5 on the beam set's erlang_28 — nixpkgs
    # carries it, no pin, no probe gate (the toolchain pattern; the mise
    # binary pin, its activation fragment and the .config/mise composition
    # retired with the lane)
    home.packages = [ pkgs.beam.packages.erlang_28.elixir ];

    workstation.editor.languages = [
      {
        id = "elixir";
        lazyvim_extras = [ "lazyvim.plugins.extras.lang.elixir" ];
        mason_packages = [ "elixir-ls" ];
        plugin_module = "languages.plugins.elixir";
      }
    ];

    workstation.editor.languagePlugins = [
      ./files/languages/plugins/elixir.lua
    ];
  };
}
