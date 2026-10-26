# The VM test host: a minimal QEMU NixOS carrying the full workstation
# substrate (system plane + home plane). The boot proves the whole seam
# LIVE, not just boot-to-activation:
#
#   workstation-e2e runs after the activation proof, as the vm user:
#     1. the RETIREMENT holds: no daemon unit staged or known, no state
#        socket anywhere under the state tree
#     2. consumer smoke: `workstation --version`, the nvim profile link,
#        the theme token path (the switch-time push surface)
#     3. an apply-driven nix switch runs (the workstation-switch driver
#        over the standalone vm@vm activationPackage — fully offline: the
#        evaluation already happened at build time on the host)
#     4. the switch receipt lands in the state tree's switch.log
#     5. read smokes: the engine answers from the baked eval report
#
# `tests/nix/run-vm.sh` builds system.build.vm, boots it, and greps the
# serial console for the OK marker and any FAIL line.
{ self, config, qemuVmModule, engine, ... }:
let
  # x86_64-linux is this VM's system (the host leg that runs it).
  pkgs = import self.inputs.nixpkgs { system = "x86_64-linux"; };
  # the foundation domain's pin surface: the hsql skill's version rides the
  # flake's pin-override overlay (the raw pinned nixpkgs predates hsql) —
  # the E2E asserts the deployed skill against THIS version
  harlequinVersion = (import self.inputs.nixpkgs {
    system = "x86_64-linux";
    overlays = [ self.overlays.default ];
  }).harlequin.version;
  e2e = pkgs.callPackage ./vm-e2e.nix { inherit self harlequinVersion; };
in
{
  imports = [ qemuVmModule ];

  workstation.enable = true;

  # host identity: the proof host's facts (consumers derive; the flake's
  # "vm-test" configuration key matches this name)
  workstation.host.name = "vm-test";
  # the canonical declaration derives from the identity option — never a
  # second literal
  networking.hostName = config.workstation.host.name;

  users.users.vm = {
    isNormalUser = true;
    home = "/home/vm";
    description = "Workstation VM test user";
    # the user manager must run at BOOT for the e2e's retirement probe
    # (systemctl --user) — no login happens on this headless proof host
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
      # the VM persona's declared home — the shared body (also the
      # standalone vm@vm configuration the E2E applies)
      ./vm-home.nix
      ../../nix/modules/workstation-home.nix
    ];
  };

  # the standalone home the switch driver applies: pulled into the VM
  # closure so the E2E's apply step never evaluates (the boot store is the
  # whole world on this offline host)
  environment.systemPackages = [
    self.homeConfigurations."vm@vm".activationPackage
  ];

  # the boot-to-activation proof: one oneshot unit ordered after the home
  # activation and multi-user, printing to journal+console so the serial
  # log carries the three markers run-vm.sh greps for. This is the VM
  # proof host's scaffolding — the substrate module carries no platform
  # branches, so the proof lives here.
  systemd.services.workstation-proof = {
    description = "Workstation boot-to-activation proof";
    wantedBy = [ "multi-user.target" ];
    after = [ "multi-user.target" "home-manager-vm.service" ];
    wants = [ "home-manager-vm.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
    script = ''
      echo "workstation: engine staged at ${engine}/bin/workstation (system plane)"
      echo "workstation: home plane active (home-manager activation completed)"
      echo "workstation: boot-to-activation proof complete (multi-user reached)"
    '';
  };

  # the live proof, run as the vm user. Ordering: wanted by multi-user
  # only — the proof unit's `after multi-user` makes any service-level
  # after/wants chain here an ordering cycle (systemd would delete this
  # job to break it); the e2e runs after the boot-home activation has
  # landed, which multi-user + home-manager-vm.service guarantee.
  systemd.services.workstation-e2e = {
    description = "Workstation E2E: retirement proof + apply-driven switch + read smokes";
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
