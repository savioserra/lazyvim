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
        marker = "# chezmoi: managed op env";
        payload = ./fragments/managed-op-env.sh;
      }
    ];

    home.file.".local/bin/op".source = "${op}/op";
  };
}
