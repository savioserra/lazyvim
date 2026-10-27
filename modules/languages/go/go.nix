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
    version = "1.27.1";
    url = {
      linux_x86_64 = "https://go.dev/dl/go{V}.linux-amd64.tar.gz";
      darwin_arm64 = "https://go.dev/dl/go{V}.darwin-arm64.tar.gz";
    };
    sha256 = {
      linux_x86_64 = "63d339f0da5ab53635a56f2490a7984dfe12dfcff22ad749f63edaf590168445";
      darwin_arm64 = "ee215d57e0ec269c60cc9ceca68e6bda321ba9ee5afe24f4b0988703c2d87d12";
    };
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
