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
    # the foundation domain's pin surface (the input law: each domain owns
    # its pins): harlequin + hsql ship as ONE upstream distribution, and
    # the pinned nixpkgs (25.05) predates hsql — the foundation's tool
    # rides this input through the pin-override overlay
    nixpkgs-foundation.url = "github:NixOS/nixpkgs/nixos-unstable";

    # the agent domain's pin surface: hermes-agent, pinned by fetchGit rev
    # (outputs.hermesAgentPin surfaces it as programs.hermes.pin; the
    # checkout stays hot home — the pin owns where it points). A pin bump
    # moves this rev and the consumer together, then `nix flake lock`.
    # The input's own dependency tree stays its own — never traverse
    # inputs (only the source tree is read).
    hermes-agent.url = "git+https://github.com/NousResearch/hermes-agent?rev=b23600860f82bd66d345c0a1baefd0f264605955";
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      nixos-wsl,
      nix-darwin,
      nixpkgs-foundation,
      hermes-agent,
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
      # shapes are the contract (docs/endgame.md):
      #   status       the declared inventory — counts + capability order
      #   plan         the surface the next switch applies, with the
      #                report digest (the declared state's content id)
      #   capabilities the per-capability accounting keyed by id — scope
      #                reads with an attrpath (#...capabilities.editor)
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
        };
        capabilities = builtins.listToAttrs (
          map (row: nixpkgs.lib.nameValuePair row.id row) report.accounting
        );
      };

      # per-host identity lives ONLY in hosts/<host>/default.nix: the flake
      # derives the rebuild key and every username/home path from the host
      # module — this body carries zero personal strings (the identity gate
      # in check.sh enforces it)
      # the two legs the flake targets: the linux leg (WSL counted under
      # it) and the mac leg — operator ruling 2026-10-22 (platform-two;
      # no distro-named legs anywhere)
      linuxHost = import ./hosts/linux/default.nix {
        inherit
          self
          nixpkgs
          home-manager
          nixos-wsl
          ;
      };

      macHost = import ./hosts/mac/default.nix {
        inherit
          self
          nixpkgs
          home-manager
          nix-darwin
          ;
      };
      # the two standalone home configurations (the linux leg's rebuild key
      # + the VM persona): bound here so the outputs and the checks read
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
            }
          )
          ./nix/modules/workstation-home.nix
        ];
      };

      # the VM's standalone home: the exact shape the linux leg applies —
      # and the E2E's apply target inside the offline VM (the shared VM
      # persona body: tests/nix/vm-home.nix)
      vmHome = home-manager.lib.homeManagerConfiguration {
        pkgs = import nixpkgs {
          system = hostSystem;
          overlays = [ self.overlays.default ];
          config.allowUnfreePredicate = licensePredicate;
        };
        extraSpecialArgs = {
          inherit self;
        };
        modules = [
          {
            nixpkgs.overlays = [ self.overlays.default ];
            nixpkgs.config.allowUnfreePredicate = licensePredicate;
          }
          ./tests/nix/vm-home.nix
          ./nix/modules/workstation-home.nix
        ];
      };

      # the VM proof host: bound here so the outputs and the checks' e2e
      # gate read the same configuration
      vmTestConfig = nixpkgs.lib.nixosSystem {
        system = hostSystem;
        specialArgs = {
          inherit self;
          # resolved at the flake level: forcing pkgs inside a module's
          # imports re-enters _module.args.pkgs (infinite recursion)
          qemuVmModule = "${nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix";
        };
        modules = [
          (
            { ... }:
            {
              # the domains' pin surface (version-currency overrides) and
              # the secrets domain's license acceptance
              nixpkgs.overlays = [ self.overlays.default ];
              nixpkgs.config.allowUnfreePredicate = licensePredicate;
            }
          )
          ./nix/modules/workstation-system.nix
          ./nix/modules/host.nix
          home-manager.nixosModules.home-manager
          ./tests/nix/vm-host.nix
        ];
      };
    in
    {
      workstation.report = reportVerbs;

      # the rebuild key is DERIVED from the host identity (${user}@<host>),
      # never hand-typed
      homeConfigurations.${linuxHost.homeKey} = linuxHome;
      homeConfigurations."vm@vm" = vmHome;

      # the mac leg: nix-darwin + the substrate. Brew keeps ONLY casks
      # (GUI apps); every retired-from-brew formula must exist in the nix
      # set or the eval fails.
      darwinConfigurations.${macHost.hostKey} = macHost.darwinConfig;

      nixosConfigurations.${linuxHost.name} = linuxHost.nixosConfig;

      # the capability outputs consumer flakes take (binding spec
      # 2026-10-22): the agent's managed skills and the theme tokens
      hermesSkills = import ./modules/agent/skills.nix { inherit self; };

      # the agent domain's runtime pin, surfaced to programs.hermes.pin
      # (modules/agent/agent.nix reads it off `self`): the clone URL, the
      # pinned rev (the input's sourceInfo — the fetchGit pin), and the
      # pinned tree (build-time assertions only; never a closure member)
      hermesAgentPin = {
        url = "https://github.com/NousResearch/hermes-agent";
        rev = hermes-agent.sourceInfo.rev;
        tree = hermes-agent;
      };

      workstationTheme.lib = import ./modules/theme/theme.nix {
        lib = nixpkgs.lib;
        inherit self;
      };

      homeManagerModules.workstation = ./nix/modules/workstation-home.nix;

      # pin overrides ONLY: the domains' version-currency surface lives
      # here (operator ruling 2026-10-27 — the download pins retired,
      # nixpkgs owns the tools). Each row pulls the named tool from the
      # foundation input (nixos-unstable, locked) because the pinned 25.05
      # set predates the floor the owning module asserts; a lagging lock
      # dies loudly at the floor. THE OVERRIDES MAY NOT RETARGET A NAME
      # NIXPKGS-INTERNAL PACKAGES CONSUME AS A BUILD INPUT: the editor's
      # libtree-sitter is built against the pinned set's tree-sitter, and
      # swapping it underneath neovim 0.11.5 breaks the compile (tree-sitter
      # 0.26 removed ts_parser_timeout_micros) — so the workstation's
      # tree-sitter CLI rides the scoped `workstation-tree-sitter` name
      # while nixpkgs' own `tree-sitter` stays stock for the editor. The
      # foundation set carries the license acceptance too — a package's
      # meta check fires where it was constructed, and the secrets
      # domain's CLI is unfree (scoped, see nix/lib/license.nix). Nothing
      # else may enter this overlay.
      overlays.default =
        final: prev:
        let
          foundationPkgs = import nixpkgs-foundation {
            system = prev.system;
            config.allowUnfreePredicate = licensePredicate;
          };
        in
        {
          inherit (foundationPkgs)
            harlequin
            fd
            fzf
            ripgrep
            lazygit
            go
            pnpm
            nodejs_24
            python314
            _1password-cli
            nerd-fonts
            ;

          # the foundation domain's tree-sitter CLI, SCOPED: nixpkgs' own
          # `tree-sitter` name is a build input of the editor (neovim links
          # libtree-sitter from its own set) and must stay stock — see the
          # overlay's scoping rule above
          workstation-tree-sitter = foundationPkgs.tree-sitter;
        };

      nixosConfigurations.vm-test = vmTestConfig;

      # the validation surface: `nix flake check` is THE canonical entry
      # locally and in CI (the golden run-vm.sh boot is one of the checks —
      # no second, hand-rolled entry to drift). The eval gates force the
      # declared-state reads and every host leg's toplevel (eval-only:
      # nothing builds); the VM check rides the closure in as an INPUT —
      # the boot and the live E2E assertions run inside the derivation
      # (tcg where KVM is absent; the timeout is the boot bound).
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
                vm = builtins.unsafeDiscardStringContext vmHome.activationPackage.drvPath;
              }
              ''
                mkdir -p "$out"
                printf '%s\n' "$linux" > "$out/linux.drv"
                printf '%s\n' "$vm" > "$out/vm.drv"
              '';

          # the golden boot: the VM E2E (tests/nix/run-vm.sh) — the VM
          # closure rides in as an input, the script boots it and asserts
          # the activation markers + the live E2E's verdict on the serial log
          vm-e2e =
            pkgs.runCommand "workstation-check-vm-e2e"
              {
                vm = vmTestConfig.config.system.build.vm;
                script = ./tests/nix/run-vm.sh;
                nativeBuildInputs = [
                  pkgs.coreutils
                  pkgs.findutils
                  pkgs.gnugrep
                ];
              }
              ''
                export WORKSTATION_VM_BUILT="$vm"
                export WORKSTATION_VM_DISK_DIR="$TMPDIR/disk"
                mkdir -p "$WORKSTATION_VM_DISK_DIR"
                sh "$script" "$out/boot.log"
              '';
        };
    };
}
