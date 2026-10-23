# The Go language capability: the pinned toolchain (a store tree the bin
# links into directly) and the editor profile entry.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  pins = import ../../../nix/lib/pins.nix { inherit lib pkgs; };

  goTree = pins.tool "go" {
    archive = "tar.gz";
    layout = "release";
    probe = {
      argv = [ "bin/go" "version" ];
      output = "go version go{V}";
    };
  };
in
{
  config = {
    home.file.".local/bin/go".source = "${goTree}/bin/go";

    workstation.editor.languages = [
      {
        id = "go";
        requires = [ "go" ];
        lazyvim_extras = [ "lazyvim.plugins.extras.lang.go" ];
      }
    ];
  };
}
