# The network domain: the fleet transport (ssh, the dashboard's --host
# binding, all host convergence ride the tailnet).
#
# | Leg | Daemon |
# | --- | --- |
# | NixOS, darwin | services.tailscale through the system module |
# | standalone linux (systemd) | the substrate unit (workstation-tailscaled, files/tailscaled-ensure.sh); a previous install is removed, the node state kept |
#
# The host's MagicDNS name comes from workstation.host.name.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.workstation.network.enable = lib.mkEnableOption "the network domain (the tailscale transport)";

  options.workstation.network.tailscale = {
    enable = lib.mkEnableOption "the tailscale transport (the CLI on the home PATH)" // {
      default = true;
    };
    acceptDns = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Accept the tailnet's DNS settings. Declared per host; the wiring
        lands with the system module that integrates the tailnet DNS.
      '';
    };
  };

  config =
    let
      on = config.workstation.network.enable && config.workstation.network.tailscale.enable;
      # the standalone linux leg's daemon: provisioned (any previous install
      # goes), retracted when off; NixOS and darwin run the system module's
      ensure = pkgs.writeShellApplication {
        name = "workstation-tailscaled";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.diffutils
          pkgs.gnugrep
        ];
        bashOptions = [ ];
        text = "TAILSCALE_PKG=${pkgs.tailscale}\n" + builtins.readFile ./files/tailscaled-ensure.sh;
      };
    in
    lib.mkMerge [
      (lib.mkIf on {
        # the CLI + the daemon binary on the home PATH
        home.packages = [ pkgs.tailscale ];
      })
      (lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
        home.activation.ensure-tailscaled = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          ${ensure}/bin/workstation-tailscaled ${if on then "on" else "off"} ||
            echo "workstation: tailscaled provision failed — the receipt above names the step; the next apply retries"
        '';
      })
    ];
}
