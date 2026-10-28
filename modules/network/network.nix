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
    # the CLI + the daemon binary on the home PATH
    home.packages = [ pkgs.tailscale ];

    # the daemon provision: NixOS/darwin legs declare services.tailscale
    # in the system module; a standalone leg gets the ensure - enable and
    # start the unit when it exists (root via sudo), defer with the exact
    # command when it does not. Idempotent: an active unit is a no-op.
    home.activation.ensure-tailscaled = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files tailscaled.service >/dev/null 2>&1; then
        state=$(systemctl is-active tailscaled 2>/dev/null || true)
        enabled=$(systemctl is-enabled tailscaled 2>/dev/null || true)
        if [ "$state" = active ] && [ "$enabled" = enabled ]; then
          echo "workstation: tailscaled already provisioned (active, enabled)"
        elif sudo -n true 2>/dev/null; then
          sudo systemctl enable --now tailscaled &&
            echo "workstation: tailscaled provisioned (enabled + started)" ||
            echo "workstation: tailscaled provision deferred - systemctl failed"
        else
          echo "workstation: tailscaled provision deferred - run: sudo systemctl enable --now tailscaled"
        fi
      else
        echo "workstation: no tailscaled unit on this host - install tailscaled (the host's package manager) or flip the leg to a system substrate"
      fi
    '';
  };
}
