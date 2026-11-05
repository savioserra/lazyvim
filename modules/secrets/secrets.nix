# The secrets domain: the 1Password CLI and the op env fragment.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  op = pkgs._1password-cli;
in
{
  options.workstation.secrets.enable =
    lib.mkEnableOption "the 1Password CLI and its env fragment"
    // {
      default = true;
    };

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
