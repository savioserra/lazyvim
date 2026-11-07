{
  description = "workstation — a machine's tools and configuration, declared in nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-wsl = {
      url = "github:nix-community/NixOS-WSL/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-homebrew.url = "github:zhaofengli/nix-homebrew";
    machine-files = {
      url = "path:./hosts/template";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      nixos-wsl,
      nix-darwin,
      nix-homebrew,
      machine-files,
    }:
    let
      lib = nixpkgs.lib;
      ciSystem = "x86_64-linux";
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      licensePredicate = import ./nix/lib/license.nix { inherit lib; };

      pkgsFor = lib.genAttrs systems (
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = licensePredicate;
        }
      );

      machine = import ./nix/lib/machine.nix {
        inherit lib;
        root = machine-files;
      };

      home =
        system: modules:
        home-manager.lib.homeManagerConfiguration {
          pkgs = pkgsFor.${system};
          modules = modules ++ [ ./nix/modules/workstation-home.nix ];
        };

      machineHome = home machine.system (
        machine.homeModules
        ++ [
          {
            workstation.switch.homeAttr = machine.key;
            workstation.switch.systemAttr = machine.host;
          }
        ]
      );

      linuxHost = import ./hosts/linux/default.nix {
        inherit
          nixpkgs
          home-manager
          nixos-wsl
          machine
          ;
      };
      macHost = import ./hosts/mac/default.nix {
        inherit
          nixpkgs
          home-manager
          nix-darwin
          nix-homebrew
          machine
          ;
      };

      report = import ./nix/report.nix {
        inherit lib;
        eval = machineHome;
        root = self;
        inherit (machine) settings;
      };

    in
    {
      workstation = {
        inherit report;
        rev = self.rev or self.dirtyRev or "unknown";
      };

      homeConfigurations = lib.optionalAttrs (lib.hasSuffix "-linux" machine.system) {
        ${machine.key} = machineHome;
      };
      darwinConfigurations.${machine.key} = macHost.darwinConfig;
      nixosConfigurations.${machine.host} = linuxHost.nixosConfig;

      homeManagerModules.workstation = ./nix/modules/workstation-home.nix;

      workstationTheme.lib = import ./modules/theme/theme.nix { inherit lib; };

      packages = lib.genAttrs systems (
        system: import ./modules/agent/packages.nix { pkgs = nixpkgs.legacyPackages.${system}; }
      );

      checks.${ciSystem} = import ./tests/nix/checks.nix {
        inherit
          self
          nixpkgs
          home
          ciSystem
          report
          ;
        legs = {
          linux = linuxHost.nixosConfig;
          mac = macHost.darwinConfig;
          home = machineHome;
        };
      };
    };
}
