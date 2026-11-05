# The system plane on NixOS and nix-darwin: system packages and the
# tailscale service.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  cfg = config.workstation;
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  tailscaleCutover = pkgs.writeShellApplication {
    name = "workstation-tailscale-cutover";
    runtimeInputs = [ ];
    bashOptions = [ ];
    text = builtins.readFile ../../modules/network/files/tailscale-darwin-cutover.sh;
  };
in
{
  options.workstation = {
    enable = lib.mkEnableOption "the workstation substrate (the system plane of the nixpkgs-native monorepo)";

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Additional system packages for this host's workstation plane.";
    };

    network.tailscale.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        The fleet transport (ssh, the dashboard's --host binding, all host
        convergence ride it). The host's MagicDNS name comes from
        workstation.host.tailscale.fqdn.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        environment.systemPackages = [
          pkgs.tmux
          pkgs.btop
        ]
        ++ cfg.extraPackages;
        services.tailscale.enable = lib.mkIf cfg.network.tailscale.enable true;
      }
      (lib.mkIf (!isDarwin) {
        system.activationScripts.workstation = {
          deps = [ "users" ];
          text = ''
            echo "workstation: substrate staged (system plane)"
            echo "workstation: substrate staged (system plane)" > /dev/kmsg 2>/dev/null || true
          '';
        };
      })
      (lib.mkIf (isDarwin && cfg.network.tailscale.enable) {
        system.activationScripts.preActivation.text = lib.mkAfter "${tailscaleCutover}/bin/workstation-tailscale-cutover";
      })
    ]
  );
}
