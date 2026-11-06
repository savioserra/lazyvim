# The home plane: the capability modules, the workstation launcher and the
# switch driver.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [ ../../modules ];

  options.workstation = {
    switch = {
      homeAttr = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "The flake attr of this host's homeConfiguration: the switch driver's home-plane target.";
      };
      checkout = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "The workstation checkout: the launcher's flake outside a checkout.";
      };
      systemAttr = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "The flake attr of this host's system configuration: the switch driver's --system target.";
      };
    };
  };

  config = {
    home.packages = [
      (pkgs.writeShellScriptBin "workstation" (
        "WORKSTATION_JQ=\${WORKSTATION_JQ:-${pkgs.jq}/bin/jq}\n"
        + lib.optionalString (
          config.workstation.switch.checkout != null
        ) "WORKSTATION_CHECKOUT=\${WORKSTATION_CHECKOUT:-${config.workstation.switch.checkout}}\n"
        + builtins.readFile ../../bin/workstation
      ))
      (import ../workstation-switch.nix {
        inherit pkgs;
        homeAttr = config.workstation.switch.homeAttr;
        systemAttr = config.workstation.switch.systemAttr;
      })
    ];

    home.stateVersion = "25.05";
    home.backupFileExtension = "hm-backup";
  };
}
