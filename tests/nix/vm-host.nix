# The VM test host: a minimal QEMU NixOS carrying the full workstation
# substrate (system plane + home plane + daemon user unit). This is the
# boot-to-activation E2E the card demands — `tests/nix/run-vm.sh` builds
# system.build.vm and boots it, grepping for the workstation markers.
{ self, qemuVmModule, engine, ... }:
{
  imports = [ qemuVmModule ];

  workstation.enable = true;

  users.users.vm = {
    isNormalUser = true;
    home = "/home/vm";
    description = "Workstation VM test user";
  };

  # minimal QEMU disk (the classic build-vm shape)
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoFormat = true;
  };
  # serial console: systemd (and the workstation activation markers) must
  # reach ttyS0 or the boot-to-activation proof has nothing to grep. The
  # default consoleLogLevel (4) suppresses info-level lines — unit starts,
  # targets, activation echoes — so raise it for the proof boot.
  boot.consoleLogLevel = 7;
  boot.kernelParams = [ "console=ttyS0" ];
  virtualisation = {
    memorySize = 2048;
    # headless: without this the bochs framebuffer takes over as the
    # primary console mid-boot and the serial log loses everything after
    graphics = false;
  };

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = { inherit self engine; };
    users.vm = import ../../nix/modules/workstation-home.nix;
  };

  system.stateVersion = "25.05";
}
