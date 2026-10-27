# The host identity options: the typed surface hosts/<host>/default.nix is
# the only place to WRITE. Every consumer — the tailscale transport, the
# dashboard's --host binding, the flake's configuration keys — derives from
# config.workstation.host.*; no module hand-types an identity fact.
# Imported by every system-level leg (NixOS, nix-darwin); the HM home scope
# carries no identity of its own.
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
    tailscale.fqdn = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        The host's tailscale FQDN (MagicDNS). The fleet transport and any
        host-binding consumer (the dashboard's --host bind) derive from it;
        a consumer that needs it fails loudly when the host never declared it.
      '';
    };
  };
}
