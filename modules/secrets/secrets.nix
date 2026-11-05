# The secrets domain: the nixpkgs 1Password CLI and the op environment
# fragment. The vault
# stays user-owned; the substrate never reads it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # The vault stays user-owned; this package never touches account or session state — the fragment only
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
