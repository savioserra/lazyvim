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

      # the declared-state report: the capability modules' fold
      # (nix/report.nix) at this tree — the ONE read source. `nix eval
      # .#workstation.report.<verb>` answers the declared state; the
      # workstation shim's read verbs are thin wrappers over exactly these
      # attrs (bin/workstation). No release bakes it, no daemon serves it.
      report = import ./nix/report.nix {
        lib = nixpkgs.lib;
        # the fold applies the substrate's pin-override overlay itself
        # (the foundation capability's harlequin floor asserts it)
        pkgs = nixpkgs.legacyPackages.${hostSystem}.extend self.overlays.default;
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
    in
    {
      workstation.report = reportVerbs;

      # the rebuild key is DERIVED from the host identity (${user}@<host>),
      # never hand-typed
      homeConfigurations.${linuxHost.homeKey} = home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.${hostSystem};
        extraSpecialArgs = {
          inherit self;
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
              workstation.switch.systemAttr = linuxHost.name;
            }
          )
          ./nix/modules/workstation-home.nix
        ];
      };

      # the VM's standalone home: the exact shape the linux leg applies —
      # and the E2E's apply target inside the offline VM (the shared VM
      # persona body: tests/nix/vm-home.nix)
      homeConfigurations."vm@vm" = home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.${hostSystem};
        extraSpecialArgs = {
          inherit self;
        };
        modules = [
          { nixpkgs.overlays = [ self.overlays.default ]; }
          ./tests/nix/vm-home.nix
          ./nix/modules/workstation-home.nix
        ];
      };

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

      # pin overrides ONLY: the foundation domain's pin surface lives here
      # (harlequin + hsql — one upstream distribution; the pinned nixpkgs
      # 25.05 predates hsql; the foundation module asserts the floor so an
      # unapplied overlay dies loudly). The download pins live in their
      # owning domain modules — nothing else may enter this overlay.
      overlays.default = final: prev: {
        harlequin = nixpkgs-foundation.legacyPackages.${prev.system}.harlequin;
      };

      nixosConfigurations.vm-test = nixpkgs.lib.nixosSystem {
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
