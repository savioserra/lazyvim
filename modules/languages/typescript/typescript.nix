# The typescript member: pnpm and its editor profile entry.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.workstation.languages.typescript;
  pnpm = pkgs.pnpm;
in
{
  options.workstation.languages.typescript.enable =
    lib.mkEnableOption "pnpm and the typescript editor profile";

  config = lib.mkIf (config.workstation.languages.enable && cfg.enable) {
    home.packages = [ pnpm ];

    workstation.editor = lib.mkIf config.workstation.editor.enable {
      languages = [
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

      languagePlugins = [
        ./files/languages/plugins/typescript.lua
      ];
    };
  };
}
