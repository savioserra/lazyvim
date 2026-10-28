# The TypeScript language capability: pnpm (floored), the editor
# profile entry, and the language's custom plugin module.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  # the pnpm floor guards the overlay: a lagging lock dies loud instead
  # of quietly downgrading the package manager
  pnpm =
    assert
      lib.versionAtLeast (pkgs.pnpm.version or "0") "12"
      || throw "workstation-typescript: pkgs.pnpm ${pkgs.pnpm.version or "?"} predates the floor 12 — the flake's overlays.default must be applied (nixpkgs.overlays)";
    pkgs.pnpm;
in
{
  # the selection gate (workstation.languages.typescript.enable AND the
  # domain enable — a member deploys under its domain,
  # nix/lib/selections.nix): disabled = the definitions skip, never the files
  config =
    lib.mkIf (config.workstation.languages.enable && config.workstation.languages.typescript.enable)
      {
        home.packages = [ pnpm ];

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
