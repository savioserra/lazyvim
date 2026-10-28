# The network domain: the fleet transport (ssh, the dashboard's --host
# binding, all host convergence ride the tailnet). The system legs declare
# services.tailscale through the system module; the host's MagicDNS name
# comes from workstation.host.name.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.workstation.network.enable = lib.mkEnableOption "the network domain (the tailscale transport)";

  options.workstation.network.tailscale = {
    enable = lib.mkEnableOption "the tailscale transport (the CLI on the home PATH)";
    acceptDns = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Accept the tailnet's DNS settings. Declared per host; the wiring
        lands with the system module that integrates the tailnet DNS.
      '';
    };
  };

  config = lib.mkIf (config.workstation.network.enable && config.workstation.network.tailscale.enable) {
    # the CLI on the home PATH (the daemon is the system service on
    # NixOS/darwin legs; tailscaled is the host-owned prerequisite on any
    # standalone leg)
    home.packages = [ pkgs.tailscale ];
  };
}
