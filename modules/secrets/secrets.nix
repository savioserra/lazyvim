# The secrets domain: the pinned 1Password CLI (zip flat — the op + op.sig
# pair) linked straight from the store tree, and the op environment
# fragment. The vault stays user-owned; the substrate never reads it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  pins = import ../../nix/lib/pins.nix { inherit lib pkgs; };

  op = pins.tool "onepassword_cli" {
    version = "2.39.0";
    url = {
      linux_x86_64 = "https://cache.agilebits.com/dist/1P/op2/pkg/v{V}/op_linux_amd64_v{V}.zip";
      darwin_arm64 = "https://cache.agilebits.com/dist/1P/op2/pkg/v{V}/op_darwin_arm64_v{V}.zip";
    };
    sha256 = {
      linux_x86_64 = "6fba7f376b6c6dec49f41b06408930a43ad064cce103c6a2ce5b3d0413a86434";
      darwin_arm64 = "05391d3388a0c0b4f602691bedc1ab368541c487b6f14d2e3399743b4682af67";
    };
    archive = "zip";
    layout = "flat";
    probe = {
      argv = [ "op" "--version" ];
      output = "{V}";
    };
  };
in
{
  config = {
    workstation.shell.fragments = [
      {
        target = ".profile";
        id = "managed-op-env";
        marker = "# workstation: managed op env";
        payload = ./fragments/managed-op-env.sh;
      }
    ];

    home.file.".local/bin/op".source = "${op}/op";
  };
}
