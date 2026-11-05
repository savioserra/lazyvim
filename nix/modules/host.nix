# The host identity options for the system legs.
{
  lib,
  ...
}:
{
  options.workstation.host = {
    name = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        The host's canonical name. On NixOS/darwin legs networking.hostName
        is the canonical declaration — the host module derives it from this
        option, never the other way around.
      '';
    };
    user = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "The host's operator user. Set only in hosts/<host>/default.nix.";
    };
    homeDirectory = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "The operator user's home. Set only in hosts/<host>/default.nix.";
    };
  };
}
