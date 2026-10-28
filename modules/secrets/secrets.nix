# The secrets domain: the nixpkgs 1Password CLI (operator ruling
# 2026-10-27: the pins machinery is redundant — the CLI rides the
# foundation domain's pin-override overlay, current past the retired
# 2.39.0 download pin) and the op environment fragment. The vault stays
# user-owned; the substrate never reads it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # the overlay's current CLI (the retired pin was 2.39.0; the locked
  # foundation input carries 2.41.0). The vault stays user-owned; this
  # package never touches account or session state — the fragment only
  # sources the host's env file.
  op = pkgs._1password-cli;
in
{
  # the selection gate (workstation.secrets.enable, nix/lib/selections.nix):
  # disabled = the definitions skip, never the files
  config = lib.mkIf config.workstation.secrets.enable {
    workstation.shell.fragments = [
      {
        target = ".profile";
        id = "managed-op-env";
        order = 30;
        domain = "secrets";
        marker = "# workstation: managed op env";
        payload = ./fragments/managed-op-env.sh;
      }
    ];

    home.packages = [ op ];
  };
}
