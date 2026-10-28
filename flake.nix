{
  description = "workstation — the operator's workstation state, declared in nix and rendered per-host";

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
    nixpkgs-foundation.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      nixos-wsl,
      nix-darwin,
      nixpkgs-foundation,
    }:
    let
      # the fold runs on the host system's nixpkgs; the report itself pins
      # no platform beyond that
      hostSystem = "x86_64-linux";

      # the secrets domain's license acceptance (nix/lib/license.nix) — the
      # 1Password CLI rides nixpkgs unfree, named and scoped
      licensePredicate = import ./nix/lib/license.nix { inherit (nixpkgs) lib; };

      # the declared-state report: the capability modules' fold
      # (nix/report.nix) at this tree — the ONE read source. `nix eval
      # .#workstation.report.<verb>` answers the declared state; the
      # workstation shim's read verbs are thin wrappers over exactly these
      # attrs (bin/workstation). No release bakes it, no daemon serves it.
      report = import ./nix/report.nix {
        lib = nixpkgs.lib;
        # the fold applies the substrate's pin-override overlay itself
        # (the domains' version floors assert it) and carries the license
        # acceptance
        pkgs = import nixpkgs {
          system = hostSystem;
          overlays = [ self.overlays.default ];
          config.allowUnfreePredicate = licensePredicate;
        };
        hm = home-manager.lib;
        treeRoot = self;
        # no default may bake an identity: the eval's home.homeDirectory
        # arrives per host; the report pins no home paths.
        homeDir = linuxHost.homeDir;
      };

      # the read verbs: the report's operator-facing projections. The
      # shapes are the contract (docs/architecture.md):
      #   status       the declared inventory — counts + capability order
      #   plan         the surface the next switch applies, with the
      #                report digest (the declared state's content id) and
      #                this machine's selection pins
      #   capabilities the per-capability accounting keyed by id — scope
      #                reads with an attrpath (#...capabilities.editor)
      #   selectable   the walk-derived paths a machine can pin
      #                (kind/baseline/default per path) — the shim's
      #                add|remove validate against it
      #   selections   the machine's pins + the resolved per-path rows
      #                (on/off/baseline/unavailable + dependency notes) —
      #                `workstation selected` serves this verbatim
      reportVerbs = {
        status = {
          inherit (report) counts capabilityOrder;
        };
        plan = {
          digest = builtins.hashString "sha256" (builtins.toJSON report);
          inherit (report)
            fileTargetNames
            claimTargets
            fragmentOrder
            retire
            ;
          # the selection delta: this machine's pins over the declared
          # defaults — exactly what the next switch enforces beyond them
          pins = report.selections.pins;
        };
        capabilities = builtins.listToAttrs (
          map (row: nixpkgs.lib.nameValuePair row.id row) report.accounting
        );
        inherit (report)
          selectable
          selections
          ;
      };

      # the capability selection: the machine's pins file read through the
      # shared library (validation + the walk-derived universe). The legs
      # and the e2e personas import the translation module beside
      # workstation-home.nix — the home plane is where selection applies
      selectionsLib = import ./nix/lib/selections.nix {
        lib = nixpkgs.lib;
        treeRoot = self;
      };

      # per-host identity lives ONLY in hosts/<host>/default.nix: the flake
      # derives the rebuild key and every username/home path from the host
      # module - this body carries zero personal strings (the identity gate
      # in check.sh enforces it). Two targets: linux (WSL counts under it)
      # and mac.
      linuxHost = import ./hosts/linux/default.nix {
        inherit
          self
          nixpkgs
          home-manager
          nixos-wsl
          ;
      };

      # the agent domain's outputs (skills; the pin lives in the module)
      agent = import ./modules/agent/outputs.nix { inherit self; };

      macHost = import ./hosts/mac/default.nix {
        inherit
          self
          nixpkgs
          home-manager
          nix-darwin
          ;
      };
      # the two standalone home configurations (the linux leg's rebuild key
      # + the e2e persona): bound here so the outputs and the checks read
      # the same values
      linuxHome = home-manager.lib.homeManagerConfiguration {
        # the overlay carries the domains' version floors; the license
        # acceptance carries the secrets domain's CLI
        pkgs = import nixpkgs {
          system = hostSystem;
          overlays = [ self.overlays.default ];
          config.allowUnfreePredicate = licensePredicate;
        };
        extraSpecialArgs = {
          inherit self;
        };
        modules = [
          (
            { ... }:
            {
              home.username = linuxHost.user;
              home.homeDirectory = linuxHost.homeDir;
              # the domains' pin surface (version-currency overrides) and
              # the secrets domain's license acceptance
              nixpkgs.overlays = [ self.overlays.default ];
              nixpkgs.config.allowUnfreePredicate = licensePredicate;
              # the switch driver's default targets: derived from the host
              # identity (never hand-typed)
              workstation.switch.homeAttr = linuxHost.homeKey;
              workstation.switch.systemAttr = linuxHost.name;
              # the operator's shell extras: the identity file is the
              # per-machine declaration point (shellExtras, optional)
              workstation.foundation.shell.extras = (import ./hosts/identity.nix).shellExtras or "";
            }
          )
          # this machine's capability selection (hosts/selections.nix)
          (selectionsLib.translationModule ./hosts/selections.nix)
          ./nix/modules/workstation-home.nix
        ];
      };

      # the E2E persona's standalone home: the exact shape the linux leg
      # applies — and the container E2E's apply target inside the throwaway
      # container (the shared persona body: tests/nix/e2e-home.nix). The
      # persona's selection is a tracked FIXTURE (never the operator's
      # hosts/selections.nix — the lane stays hermetic against local
      # state): the full fixture pins every language the driver asserts;
      # the minus-go fixture removes one member for the removal proof.
      e2eHomeModules = selectionsFile: [
        {
          nixpkgs.overlays = [ self.overlays.default ];
          nixpkgs.config.allowUnfreePredicate = licensePredicate;
        }
        ./tests/nix/e2e-home.nix
        (selectionsLib.translationModule selectionsFile)
        ./nix/modules/workstation-home.nix
      ];
      e2eHome = home-manager.lib.homeManagerConfiguration {
        pkgs = import nixpkgs {
          system = hostSystem;
          overlays = [ self.overlays.default ];
          config.allowUnfreePredicate = licensePredicate;
        };
        extraSpecialArgs = {
          inherit self;
        };
        modules = e2eHomeModules ./tests/nix/e2e-selections.nix;
      };
      e2eMinusGoHome = home-manager.lib.homeManagerConfiguration {
        pkgs = import nixpkgs {
          system = hostSystem;
          overlays = [ self.overlays.default ];
          config.allowUnfreePredicate = licensePredicate;
        };
        extraSpecialArgs = {
          inherit self;
        };
        modules = e2eHomeModules ./tests/nix/e2e-selections-minus-go.nix;
      };

      # the container E2E's proof driver: the lane's consumers (the
      # container script's in-container build and the check's staging)
      # read the same derivation
      e2eDriver =
        let
          e2ePkgs = import nixpkgs {
            system = hostSystem;
            overlays = [ self.overlays.default ];
            config.allowUnfreePredicate = licensePredicate;
          };
        in
        e2ePkgs.callPackage ./tests/nix/e2e.nix {
          inherit self;
          harlequinVersion = e2ePkgs.harlequin.version;
        };
    in
    {
      workstation.report = reportVerbs;

      # the rebuild key is DERIVED from the host identity (${user}@<host>),
      # never hand-typed
      homeConfigurations.${linuxHost.homeKey} = linuxHome;
      homeConfigurations."e2e@container" = e2eHome;
      # the removal proof: the persona home with go deselected
      homeConfigurations."e2e-minus-go@container" = e2eMinusGoHome;

      # the container E2E's surface — the lane's ONE wiring point: the
      # persona home (also a homeConfiguration above) and the proof driver,
      # both built inside the container from the mounted flake
      workstationE2E = {
        home = e2eHome;
        driver = e2eDriver;
      };

      # the mac leg: nix-darwin + the substrate. Brew keeps ONLY casks
      # (GUI apps); every retired-from-brew formula must exist in the nix
      # set or the eval fails.
      darwinConfigurations.${macHost.hostKey} = macHost.darwinConfig;

      nixosConfigurations.${linuxHost.name} = linuxHost.nixosConfig;

      # the capability outputs consumer flakes take: the agent's managed
      # skills and the theme tokens
      hermesSkills = agent.skills;

      workstationTheme.lib = import ./modules/theme/theme.nix {
        lib = nixpkgs.lib;
        inherit self;
      };

      homeManagerModules.workstation = ./nix/modules/workstation-home.nix;

      # the capability overlays, composed: each domain owns its tool
      # overrides (modules/<domain>/overlay.nix); the root only wires the
      # domain input into them. The license acceptance rides the
      # foundation input's import (the secrets domain's CLI is unfree -
      # nix/lib/license.nix).
      overlays.default =
        final: prev:
        let
          foundationPkgs = import nixpkgs-foundation {
            system = prev.system;
            config.allowUnfreePredicate = licensePredicate;
          };
        in
        nixpkgs.lib.composeManyExtensions (
          map (f: import f foundationPkgs) [
            ./modules/foundation/overlay.nix
            ./modules/editor/overlay.nix
            ./modules/languages/overlay.nix
            ./modules/agent/overlay.nix
          ]
        ) final prev;

      # the validation surface: `nix flake check` is the canonical entry.
      # Eval gates force the declared-state reads and every host leg's
      # toplevel (eval-only). The container E2E check stages the lane
      # entry; the behavioral run happens on a docker host (CI's
      # container-e2e job, or the host shell - docs/testing.md).
      checks.${hostSystem} =
        let
          pkgs = import nixpkgs { system = hostSystem; };
        in
        {
          # the declared-state reads answer: the fold evaluated through the
          # read verbs' projection (the shim's contract)
          report-reads =
            pkgs.runCommand "workstation-check-report-reads"
              {
                report = builtins.toJSON reportVerbs;
                passAsFile = [ "report" ];
              }
              ''
                mkdir -p "$out"
                mv "$reportPath" "$out/report.json"
              '';

          # every host leg still evaluates — toplevel drvPath forces the
          # full evaluation of each leg and builds nothing. The drvPath's
          # string context is discarded ON PURPOSE: kept, the context makes
          # nix realize the leg's whole closure as a dependency of this
          # check — a darwin closure is unbuildable on a linux host and an
          # eval gate must never schedule builds (producing the drvPath
          # here already forced the leg's evaluation, which is the proof).
          linux-leg-eval =
            pkgs.runCommand "workstation-check-linux-leg-eval"
              {
                toplevel = builtins.unsafeDiscardStringContext linuxHost.nixosConfig.config.system.build.toplevel.drvPath;
              }
              ''
                mkdir -p "$out"
                printf '%s\n' "$toplevel" > "$out/toplevel.drv"
              '';
          mac-leg-eval =
            pkgs.runCommand "workstation-check-mac-leg-eval"
              {
                toplevel = builtins.unsafeDiscardStringContext macHost.darwinConfig.config.system.build.toplevel.drvPath;
              }
              ''
                mkdir -p "$out"
                printf '%s\n' "$toplevel" > "$out/toplevel.drv"
              '';
          home-legs-eval =
            pkgs.runCommand "workstation-check-home-legs-eval"
              {
                linux = builtins.unsafeDiscardStringContext linuxHome.activationPackage.drvPath;
                e2e = builtins.unsafeDiscardStringContext e2eHome.activationPackage.drvPath;
                e2e-minus-go = builtins.unsafeDiscardStringContext e2eMinusGoHome.activationPackage.drvPath;
              }
              ''
                mkdir -p "$out"
                printf '%s\n' "$linux" > "$out/linux.drv"
                printf '%s\n' "$e2e" > "$out/e2e.drv"
                printf '%s\n' "$e2e-minus-go" > "$out/e2e-minus-go.drv"
              '';

          # the container E2E lane: stages THE entry (bin/run-container-e2e)
          # — the lane script plus the flake source it mounts, so the
          # staged run proves the checked-out tree with zero flags. The
          # behavioral run happens on a docker host (CI's container-e2e
          # job runs exactly this artifact; a host without nix runs the
          # script straight from a checkout).
          container-e2e =
            pkgs.runCommand "workstation-check-container-e2e"
              {
                src = self;
                script = ./tests/nix/run-container.sh;
                nativeBuildInputs = [ pkgs.coreutils ];
              }
              ''
                # nix creates no output paths on the builder
                mkdir -p "$out/bin" "$out/share"
                install -m 0755 "$script" "$out/bin/run-container-e2e"
                # the flake source the lane mounts (the staged form); the
                # context keeps the source alive for the GC while the
                # entry artifact exists
                printf '%s\n' "$src" > "$out/share/flake-src"
                # the staged entry parses (the shell battery owns the
                # full lint)
                sh -n "$out/bin/run-container-e2e"
              '';
        };
    };
}
