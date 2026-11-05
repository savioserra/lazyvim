# The network domain: tailscale. Standalone linux runs the substrate's
# tailscaled unit (files/tailscaled-ensure.sh); NixOS and darwin run
# services.tailscale.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.workstation.network.enable = lib.mkEnableOption "tailscale, the fleet transport";

  config =
    let
      on = config.workstation.network.enable;
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
      (lib.mkIf (on && pkgs.stdenv.hostPlatform.isLinux) {
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
