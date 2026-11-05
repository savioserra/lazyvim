# The home plane: the capability modules, the workstation launcher and the
# switch driver.
{
  config,
  lib,
  pkgs,
  self,
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
      systemAttr = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "The flake attr of this host's system configuration: the switch driver's --system target.";
      };
    };
  };

  config = {
    home.file.".local/opt/workstation/flake".source = self;

    home.packages = [
      (pkgs.writeShellScriptBin "workstation" (
        "WORKSTATION_JQ=\${WORKSTATION_JQ:-${pkgs.jq}/bin/jq}\n"
        + builtins.readFile (self + "/bin/workstation")
      ))
      (import ../workstation-switch.nix {
        inherit pkgs;
        flake = self;
        homeAttr = config.workstation.switch.homeAttr;
        systemAttr = config.workstation.switch.systemAttr;
      })
    ];

    home.stateVersion = "25.05";
  };
}
