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
    machine-files = {
      url = "path:./hosts";
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
          machine
          ;
      };

      report = import ./nix/report.nix {
        inherit lib;
        eval = machineHome;
        root = self;
        inherit (machine) settings;
      };

      e2eHome =
        selections:
        (home ciSystem [
          ./tests/nix/e2e-home.nix
          selections
        ]).activationPackage;

      evalCheck =
        name: drvPath:
        pkgsFor.${ciSystem}.runCommand "workstation-check-${name}"
          {
            drv = builtins.unsafeDiscardStringContext drvPath;
          }
          ''
            mkdir -p "$out"
            printf '%s\n' "$drv" > "$out/drv"
          '';
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

      checks.${ciSystem} =
        let
          pkgs = nixpkgs.legacyPackages.${ciSystem};
        in
        {
          report-reads = pkgs.runCommand "workstation-check-report-reads" {
            report = builtins.toJSON report;
            passAsFile = [ "report" ];
          } ''mkdir -p "$out" && mv "$reportPath" "$out/report.json"'';

          linux-leg-eval = evalCheck "linux-leg-eval" linuxHost.nixosConfig.config.system.build.toplevel.drvPath;
          mac-leg-eval = evalCheck "mac-leg-eval" macHost.darwinConfig.config.system.build.toplevel.drvPath;
          home-legs-eval = evalCheck "home-legs-eval" machineHome.activationPackage.drvPath;

          e2e-home = e2eHome ./tests/nix/e2e-selections.nix;
          e2e-minus-go-home = e2eHome ./tests/nix/e2e-selections-minus-go.nix;
          e2e-driver = pkgs.callPackage ./tests/nix/e2e.nix {
            inherit self;
            harlequinVersion = pkgs.harlequin.version;
          };

          container-e2e =
            pkgs.runCommand "workstation-check-container-e2e"
              {
                src = self;
                script = ./tests/nix/run-container.sh;
              }
              ''
                mkdir -p "$out/bin" "$out/share"
                install -m 0755 "$script" "$out/bin/run-container-e2e"
                printf '%s\n' "$src" > "$out/share/flake-src"
                sh -n "$out/bin/run-container-e2e"
              '';
        };
    };
}
