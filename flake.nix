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
  };

  outputs =
    { self, nixpkgs, home-manager, nixos-wsl }:
    let
      # the engine builds where its NIF vendoring is proven (P0):
      # x86_64-linux built + smoked; aarch64-darwin evals clean, its
      # per-target NIF artifacts are the named gap
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
      wslHost = import ./hosts/wsl/default.nix {
        inherit self nixpkgs home-manager nixos-wsl;
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
        homeDir = wslHost.homeDir;
      }).report
      // {
        # the `system` overlay domain's publish contract (the nix side of
        # the two-reader drift guard — see nix/system-domain.nix)
        systemDomain = import ./nix/system-domain.nix;
      };

      # the rebuild key is DERIVED from the host identity (${user}@<host>),
      # never hand-typed
      homeConfigurations.${wslHost.homeKey} = home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.${hostSystem};
        extraSpecialArgs = {
          inherit self;
          engine = self.packages.${hostSystem}.workstation;
        };
        modules = [
          (
            { ... }:
            {
              home.username = wslHost.user;
              home.homeDirectory = wslHost.homeDir;
            }
          )
          ./nix/modules/workstation-home.nix
        ];
      };

      nixosConfigurations.wsl = wslHost.nixosConfig;

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
          home-manager.nixosModules.home-manager
          ./tests/nix/vm-host.nix
        ];
      };
    };
}
