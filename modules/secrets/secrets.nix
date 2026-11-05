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
    home.sessionVariablesExtra = ''
      [ -r /etc/pi/op.env ] && { set -a; . /etc/pi/op.env; set +a; }
    '';

    home.packages = [ op ];
  };
}
