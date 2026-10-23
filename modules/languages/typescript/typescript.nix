# The TypeScript language capability: the pinned pnpm standalone tree, the
# editor profile entry, and the language's custom plugin module.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  pins = import ../../../nix/lib/pins.nix { inherit lib pkgs; };

  pnpm = pins.tool "pnpm" {
    archive = "tar.gz";
    layout = "flat";
    probe = {
      argv = [ "pnpm" "--version" ];
      output = "{V}";
    };
  };
in
{
  config = {
    home.file.".local/bin/pnpm".source = "${pnpm}/pnpm";

    workstation.editor.languages = [
      {
        id = "typescript";
        requires = [ "node" ];
        lazyvim_extras = [
          "lazyvim.plugins.extras.lang.typescript"
          "lazyvim.plugins.extras.linting.eslint"
          "lazyvim.plugins.extras.formatting.prettier"
        ];
        mason_packages = [
          "typescript-language-server"
          "eslint-lsp"
          "prettier"
        ];
        plugin_module = "languages.plugins.typescript";
      }
    ];

    workstation.editor.languagePlugins = [
      (self + "/workstation/packages/languages/typescript/files/languages/plugins/typescript.lua")
    ];
  };
}
