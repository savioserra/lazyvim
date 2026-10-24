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

  # go's --version vocabulary: GOOS/GOARCH (the two platform legs the
  # substrate targets)
  goOs = pkgs.stdenv.hostPlatform.parsed.kernel.name;
  goArch = if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "amd64";
  goTree = pins.tool "go" {
    archive = "tar.gz";
    layout = "release";
    probe = {
      argv = [ "bin/go" "version" ];
      output = "go version go{V} ${goOs}/${goArch}";
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
