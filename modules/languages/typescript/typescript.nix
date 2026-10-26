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
    version = "12.14.0";
    url = {
      linux_x86_64 = "https://github.com/pnpm/pnpm/releases/download/v{V}/pnpm-linux-x64.tar.gz";
      darwin_arm64 = "https://github.com/pnpm/pnpm/releases/download/v{V}/pnpm-darwin-arm64.tar.gz";
    };
    sha256 = {
      linux_x86_64 = "3910c3852136bed5bc1511b9137a45fd4357ed6b3970d9d08893641e9005867e";
      darwin_arm64 = "50f48e0e17508952790a3fbf58fcf14f3b82efa5f594ca04ad904e29aaf854b0";
    };
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
      (self + "/modules/languages/typescript/files/languages/plugins/typescript.lua")
    ];
  };
}
