# The VM test host: a minimal QEMU NixOS carrying the full workstation
# substrate (system plane + home plane + daemon user unit). The boot
# proves the whole seam LIVE, not just boot-to-activation:
#
#   workstation-e2e runs after the activation proof, as the vm user:
#     1. the daemon USER UNIT is active (lingered user manager, no login)
#     2. the wire handshake answers (a real `system.applied` op round-trip)
#     3. an apply-driven nix switch runs (the workstation-switch driver
#        over the standalone vm@vm activationPackage — fully offline: the
#        evaluation already happened at build time on the host)
#     4. the daemon HEARS the switch: the `system` domain receipt in the
#        user unit's journal
#     5. consumer smoke: `workstation --version`, the nvim profile link
#
# `tests/nix/run-vm.sh` builds system.build.vm, boots it, and greps the
# serial console for the OK marker and any FAIL line.
{ self, qemuVmModule, engine, ... }:
let
  # x86_64-linux is this VM's system (the host leg that runs it).
  pkgs = import self.inputs.nixpkgs { system = "x86_64-linux"; };
  e2e = pkgs.callPackage ./vm-e2e.nix { inherit self engine; };
in
{
  imports = [ qemuVmModule ];

  workstation.enable = true;

  users.users.vm = {
    isNormalUser = true;
    home = "/home/vm";
    description = "Workstation VM test user";
    # the user manager must run at BOOT for the daemon user unit — no
    # login happens on this headless proof host
    linger = true;
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
    users.vm.imports = [
      (
        { ... }:
        {
          home.username = "vm";
          home.homeDirectory = "/home/vm";
          # the switch driver's default targets inside the VM
          workstation.switch.homeAttr = "vm@vm";
          workstation.switch.systemAttr = "vm-test";
        }
      )
      ../../nix/modules/workstation-home.nix
    ];
  };

  # the standalone home the switch driver applies: pulled into the VM
  # closure so the E2E's apply step never evaluates (the boot store is the
  # whole world on this offline host)
  environment.systemPackages = [
    self.homeConfigurations."vm@vm".activationPackage
  ];

  # the live proof, run as the vm user. Ordering: wanted by multi-user
  # only — the proof unit's `after multi-user` makes any service-level
  # after/wants chain here an ordering cycle (systemd would delete this
  # job to break it); the script's own bounded socket wait is the
  # sequencing contract, not unit ordering.
  systemd.services.workstation-e2e = {
    description = "Workstation E2E: daemon user unit + wire handshake + apply-driven switch";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = "vm";
      RemainAfterExit = true;
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
    script = "${e2e}/bin/workstation-e2e";
  };

  system.stateVersion = "25.05";
}
