# The TypeScript language capability: the nixpkgs pnpm (floored at the
# retired download pin's major — operator ruling 2026-10-27: the pins
# machinery is redundant), the editor profile entry, and the language's
# custom plugin module.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  # the pnpm floor guards the overlay: the pinned 25.05 set carries pnpm
  # 10 — the foundation input's current 12.x is the declared surface, and
  # an unapplied overlay (or a lagging lock) dies here instead of quietly
  # downgrading the operator's package manager (the retired pin was
  # 12.14.0; the locked foundation input carries 12.9.0 — the floor holds
  # the major, nixpkgs owns the drift)
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
