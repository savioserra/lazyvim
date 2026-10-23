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
  };

  outputs =
    { self, nixpkgs, home-manager, nixos-wsl, nix-darwin }:
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

      # the walker's report at this tree — byte-compared against
      # tests/nix/goldens/eval-report.json by .github/scripts/eval-goldens.sh
      evalReport.${hostSystem} = (import ./nix/manifest-lib.nix {
        lib = nixpkgs.lib;
        pkgs = nixpkgs.legacyPackages.${hostSystem};
        treeRoot = self;
        # the walker takes no default: identity must arrive per host. The
        # report itself pins no home paths (the golden stays byte-stable),
        # but the argument stays required so no caller can inherit a name.
        homeDir = linuxHost.homeDir;
      }).report
      // {
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
          ./nix/modules/workstation-system.nix
          ./nix/modules/host.nix
          home-manager.nixosModules.home-manager
          ./tests/nix/vm-host.nix
        ];
      };
    };
}
