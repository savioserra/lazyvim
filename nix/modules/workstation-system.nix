# The system leg: the substrate's system plane on a NixOS system — the
# nixpkgs toolchains and the transport wiring. The workstation client is a
# HOME lane concern (the launcher shim and the switch driver stage into the
# user's profile); this module owns the system plane only:
#   - the nixpkgs toolchains the retired mise pins used to provide
#     (tmux, btop — versions now nixpkgs-owned)
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  cfg = config.workstation;
in
{
  options.workstation = {
    enable = lib.mkEnableOption "the workstation substrate (the system plane of the nixpkgs-native monorepo)";

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Additional system packages for this host's workstation plane.";
    };

    # the tailscale transport (the fleet's layer) — declared per host;
    # options mirrored at home scope by modules/foundation/foundation.nix
    foundation.tailscale.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        The fleet transport (ssh, the dashboard's --host binding, all host
        convergence ride it). The host's MagicDNS name comes from
        workstation.host.tailscale.fqdn.
      '';
    };
    foundation.tailscale.acceptDns = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Accept the tailnet's DNS settings on the transport. Declared per
        host; the wiring lands with the first transport module that carries
        the option (the NixOS module integrates the tailnet DNS on enable).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      # the toolchain replacements (the terminal/tmux lane:
      # tmux 3.7c, btop 1.4.7 — versions now nixpkgs-owned)
      pkgs.tmux
      pkgs.btop
    ]
    ++ cfg.extraPackages;
    # --- the tailscale transport (the fleet's layer) -----------------------
    # ssh, the dashboard's --host binding and all host convergence ride it;
    # the host's MagicDNS name is workstation.host.tailscale.fqdn (set only
    # in hosts/<host>/default.nix). acceptDns stays the declared surface —
    # neither the NixOS nor the nix-darwin module carried the option at the
    # pin; the NixOS module integrates the tailnet DNS through the resolver
    # on enable.
    services.tailscale.enable = lib.mkIf cfg.foundation.tailscale.enable true;

    # activation marker (kmsg surfaces on the serial console; plain stdout
    # serves human `switch` runs)
    system.activationScripts.workstation = {
      deps = [ "users" ];
      text = ''
        echo "workstation: substrate staged (system plane)"
        echo "workstation: substrate staged (system plane)" > /dev/kmsg 2>/dev/null || true
      '';
    };
  };
}
