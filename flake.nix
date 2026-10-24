{
  description = "workstation — the engine-owned workstation state, rendered per-host by nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-wsl = {
      url = "github:nix-community/NixOS-WSL/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-darwin = {
      url = "github:LnL7/nix-darwin/nix-darwin-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # the foundation domain's pin surface (the input law: each domain owns
    # its pins): harlequin + hsql ship as ONE upstream distribution, and
    # the pinned nixpkgs (25.05) predates hsql — the foundation's tool
    # rides this input through the pin-override overlay
    nixpkgs-foundation.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs, home-manager, nixos-wsl, nix-darwin, nixpkgs-foundation }:
    let
      # the engine builds where its NIF vendoring is proven (the build
      # gate): x86_64-linux built + smoked; aarch64-darwin evals clean,
      # its per-target NIF artifacts are the named gap
      buildSystems = [ "x86_64-linux" "aarch64-darwin" ];
      hostSystem = "x86_64-linux";

      engineFor = system:
        nixpkgs.legacyPackages.${system}.callPackage ./nix/engine.nix {
          beamPackages = nixpkgs.legacyPackages.${system}.beam.packages.erlang_28;
          src = self;
          # the declared-state report bakes into the release: reads serve
          # the same flake snapshot that built it. The fold evals on the
          # host system only — the other build system's release fails its
          # reads closed until the fold grows that platform.
          report =
            if system == hostSystem
            then builtins.toJSON self.evalReport.${hostSystem}
            else null;
        };

      # per-host identity lives ONLY in hosts/<host>/default.nix: the flake
      # derives the rebuild key and every username/home path from the host
      # module — this body carries zero personal strings (the identity gate
      # in check.sh enforces it)
      # the two legs the flake targets: the linux leg (WSL counted under
      # it) and the mac leg — operator ruling 2026-10-22 (platform-two;
      # no distro-named legs anywhere)
      linuxHost = import ./hosts/wsl/default.nix {
        inherit self nixpkgs home-manager nixos-wsl;
      };

      macHost = import ./hosts/mac/default.nix {
        inherit self nixpkgs home-manager nix-darwin;
      };
    in
    {
      packages = nixpkgs.lib.genAttrs buildSystems
        (system: { workstation = engineFor system; });

      # the declared-state report: the capability modules' fold
      # (nix/report.nix) at this tree. The engine's release bakes the same
      # JSON (nix/engine.nix), so release and declared state ship from the
      # one flake snapshot.
      evalReport.${hostSystem} =
        (import ./nix/report.nix {
          lib = nixpkgs.lib;
          # the fold applies the substrate's pin-override overlay itself
          # (the foundation capability's harlequin floor asserts it)
          pkgs = nixpkgs.legacyPackages.${hostSystem}.extend self.overlays.default;
          hm = home-manager.lib;
          treeRoot = self;
          # no default may bake an identity (t_40cf3088): the eval's
          # home.homeDirectory arrives per host; the report pins no home
          # paths.
          homeDir = linuxHost.homeDir;
        }) // {
          # the `system` overlay domain's publish contract (the nix side of
          # the two-reader drift guard — see nix/system-domain.nix)
          systemDomain = import ./nix/system-domain.nix;
        };

      # the rebuild key is DERIVED from the host identity (${user}@<host>),
      # never hand-typed
      homeConfigurations.${linuxHost.homeKey} = home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.${hostSystem};
        extraSpecialArgs = {
          inherit self;
          engine = self.packages.${hostSystem}.workstation;
        };
        modules = [
          (
            { ... }:
            {
              home.username = linuxHost.user;
              home.homeDirectory = linuxHost.homeDir;
              # the foundation domain's pin surface (harlequin + hsql)
              nixpkgs.overlays = [ self.overlays.default ];
              # the switch driver's default targets: derived from the host
              # identity (never hand-typed)
              workstation.switch.homeAttr = linuxHost.homeKey;
              workstation.switch.systemAttr = "wsl";
            }
          )
          ./nix/modules/workstation-home.nix
        ];
      };

      # the VM's standalone home: the exact shape the linux leg applies —
      # and the E2E's apply target inside the offline VM
      homeConfigurations."vm@vm" = home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.${hostSystem};
        extraSpecialArgs = {
          inherit self;
          engine = self.packages.${hostSystem}.workstation;
        };
        modules = [
          (
            { ... }:
            {
              home.username = "vm";
              home.homeDirectory = "/home/vm";
              # the foundation domain's pin surface (harlequin + hsql)
              nixpkgs.overlays = [ self.overlays.default ];
              # the switch driver's default targets inside the VM
              workstation.switch.homeAttr = "vm@vm";
              workstation.switch.systemAttr = "vm-test";
            }
          )
          ./nix/modules/workstation-home.nix
        ];
      };

      # the mac leg: nix-darwin + the substrate. Brew keeps ONLY casks
      # (GUI apps); every retired-from-brew formula must exist in the nix
      # set or the eval fails.
      darwinConfigurations.${macHost.hostKey} = macHost.darwinConfig;

      nixosConfigurations.wsl = linuxHost.nixosConfig;

      # the capability outputs consumer flakes take (binding spec
      # 2026-10-22): the agent's managed skills and the theme tokens
      hermesSkills = import ./modules/agent/skills.nix { inherit self; };

      workstationTheme.lib = import ./modules/theme/theme.nix {
        lib = nixpkgs.lib;
        inherit self;
      };

      homeManagerModules.workstation = ./nix/modules/workstation-home.nix;

      # pin overrides ONLY: the substrate's pinned tools from the same
      # inventory the modules consume. Nothing else may enter this
      # overlay — a pin override lands here, never inside a domain module.
      overlays.default = final: prev: {
        workstationPins = import ./nix/lib/pins.nix {
          lib = final.lib;
          pkgs = final;
        };
        # the foundation domain's pin: harlequin + hsql (one upstream
        # distribution — the terminal SQL IDE and its headless agent CLI).
        # The pinned nixpkgs (25.05) predates hsql; the foundation module
        # asserts the floor so an unapplied overlay dies loudly.
        harlequin = nixpkgs-foundation.legacyPackages.${prev.system}.harlequin;
      };

      nixosConfigurations.vm-test = nixpkgs.lib.nixosSystem {
        system = hostSystem;
        specialArgs = {
          inherit self;
          engine = self.packages.${hostSystem}.workstation;
          # resolved at the flake level: forcing pkgs inside a module's
          # imports re-enters _module.args.pkgs (infinite recursion)
          qemuVmModule = "${nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix";
        };
        modules = [
          (
            { ... }:
            {
              # the foundation domain's pin surface (harlequin + hsql)
              nixpkgs.overlays = [ self.overlays.default ];
            }
          )
          ./nix/modules/workstation-system.nix
          ./nix/modules/host.nix
          home-manager.nixosModules.home-manager
          ./tests/nix/vm-host.nix
        ];
      };
    };
}
