# The go language capability: the toolchain (floored) and the
# editor profile entry.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  go = pkgs.go;
in
{
  # the selection gate (workstation.languages.go.enable AND the domain
  # enable — a member deploys under its domain, nix/lib/selections.nix):
  # disabled = the definitions skip, never the files
  config = lib.mkIf (config.workstation.languages.enable && config.workstation.languages.go.enable) {
    home.packages = [ go ];

    workstation.editor.languages = [
      {
        id = "go";
        requires = [ "go" ];
        lazyvim_extras = [ "lazyvim.plugins.extras.lang.go" ];
        # the payload spec module rides the selection: deselecting go
        # drops both the profile entry and the deployed file (the
        # editor deploy's managed-path prune)
        plugin_module = "languages.plugins.go";
      }
    ];

    workstation.editor.languagePlugins = [
      (self + "/modules/languages/go/files/languages/plugins/go.lua")
    ];
  };
}
