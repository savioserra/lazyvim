# The node member: nodejs_24 and ~/.node-version derived from it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.workstation.languages.node;
  nodejs = pkgs.nodejs_24;

  nodeVersionFile = pkgs.writeText "node-version" "${nodejs.version}\n";
in
{
  options.workstation.languages.node.enable = lib.mkEnableOption "the node runtime";

  config = lib.mkIf (config.workstation.languages.enable && cfg.enable) {
    home.packages = [ nodejs ];

    home.file.".node-version".source = nodeVersionFile;

    workstation.retire = [
      ".config/shell/nvm.sh"
      {
        path = ".local/opt/nvm";
        recursive = true;
      }
    ];
  };
}
