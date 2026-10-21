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
      }).report;

      homeConfigurations."savio@wsl" = home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.${hostSystem};
        extraSpecialArgs = {
          inherit self;
          engine = self.packages.${hostSystem}.workstation;
        };
        modules = [
          (
            { ... }:
            {
              home.username = "savio";
              home.homeDirectory = "/home/savio";
            }
          )
          ./nix/modules/workstation-home.nix
        ];
      };

      nixosConfigurations.wsl = import ./hosts/wsl/default.nix {
        inherit self nixpkgs home-manager nixos-wsl;
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
          home-manager.nixosModules.home-manager
          ./tests/nix/vm-host.nix
        ];
      };
    };
}
