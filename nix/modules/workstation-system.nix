# The system leg: the engine derivation and the nixpkgs toolchains on a
# NixOS system. The daemon runs as a USER unit (workstation-home); this
# module owns the system plane only:
#   - the engine binary on the system PATH (the .local/bin contract keeps
#     working through the home lane)
#   - the mise toolchain pins (tmux, btop) die here: nixpkgs provides the
#     toolchains (the mise envelope lane is refused in the walker)
{
  config,
  lib,
  pkgs,
  self,
  engine,
  ...
}:
let
  cfg = config.workstation;
in
{
  options.workstation = {
    enable = lib.mkEnableOption "the workstation substrate (engine + nixpkgs toolchains)";

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Additional system packages for this host's workstation plane.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      engine
      # the deleted mise pins' nixpkgs replacements (terminal/tmux manifest:
      # tmux 3.7c, btop 1.4.7 — versions now nixpkgs-owned)
      pkgs.tmux
      pkgs.btop
    ] ++ cfg.extraPackages;

    # activation marker the VM test driver greps for (boot-to-activation
    # proof, the thing synthetic fixtures never gave)
    system.activationScripts.workstation = {
      deps = [ "users" ];
      text = ''
        echo "workstation: engine staged at ${engine}/bin/workstation (system plane)"
      '';
    };
  };
}
