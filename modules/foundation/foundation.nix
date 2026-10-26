# The base shell environment: the rc lane + fd, fzf, rg, lazygit,
# tree-sitter (checksummed pins), eza + starship (nixpkgs — the prompt
# capability dissolved here), harlequin + hsql (one upstream distribution;
# the pinned nixpkgs predates hsql, so the foundation domain owns its pin
# surface through the flake's pin-override overlay), and the tailscale
# transport (the system legs declare services.tailscale through the system
# module; workstation.foundation.tailscale.* is the options surface).
#
# Shell fragments: the bodies are payload files beside this module; the
# ORDER is the explicit declared list below (id, target, marker, payload)
# — reviewed in diffs, never derived. The retired managed-mise fragment
# is gone with the mise lane. The hsql agent skill is generated from the
# INSTALLED derivation at build time (hsql --skill) — version-matched by
# construction, offline — and serves as a declared entry symlink
# (programs.hermes.skills.hsql); no activation lane writes into hot home.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  pins = import ../../nix/lib/pins.nix { inherit lib pkgs; };

  # the checksummed pins: store trees the bin links reach directly
  tools = {
    rg = pins.tool "ripgrep" {
      archive = "tar.gz";
      probe = {
        argv = [ "rg" "--version" ];
        # upstream prints the packaging rev beside the version (the release
        # identity's own suffix — moves with the pin on a bump)
        output = "ripgrep {V} (rev e89fff89ac)";
      };
    };
    fd = pins.tool "fd" {
      archive = "tar.gz";
      probe = {
        argv = [ "fd" "--version" ];
        output = "fd {V}";
      };
    };
    fzf = pins.tool "fzf" {
      archive = "tar.gz";
      probe = {
        argv = [ "fzf" "--version" ];
        # upstream prints the build commit beside the version (the release
        # identity's own suffix — moves with the pin on a bump)
        output = "{V} (3337be9d)";
      };
    };
    lazygit = pins.tool "lazygit" {
      archive = "tar.gz";
      layout = "flat";
      probe = {
        argv = [ "lazygit" "--version" ];
        output =
          "commit=aafe61082e7ed383d318fd40e48f85645e6afc7b, build date=2026-07-15T11:34:26Z, build source=binaryRelease, version={V}, os=${pkgs.stdenv.hostPlatform.parsed.kernel.name}, arch=${
            if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "amd64"
          }, git version=";
      };
    };
    tree-sitter = pins.tool "tree_sitter" {
      archive = "zip";
      probe = {
        argv = [ "tree-sitter" "--version" ];
        output = "tree-sitter {V}";
      };
    };
  };

  # the fragment payload (id -> the marker + payload path the rc lane
  # declares; bodies live beside the module at their final address). The
  # starship init is per-shell — the walker's id-keyed file map collapsed
  # the two bodies (last wins); the declared list gives each shell its own.
  frag = id: marker: {
    inherit id marker;
    payload = ./fragments + "/${id}.sh";
  };

  # the explicit declared list: the rc contract's order, per target,
  # exactly the order the manifests' topo walk used to derive (minus the
  # retired mise fragment)
  fragments = [
    (frag "user-local-bin" "# workstation: managed user-local bin")
    (frag "managed-profile" "# workstation: load managed profile")
    (frag "managed-eza" "# workstation: managed eza ls")
    (frag "managed-starship" "# workstation: managed starship prompt")
    (frag "managed-starship-zsh" "# workstation: managed starship prompt")
  ];

  fragmentTargets = {
    user-local-bin = [ ".profile" ".bashrc" ".zshrc" ];
    managed-profile = [ ".bash_profile" ];
    managed-eza = [ ".bashrc" ".zshrc" ];
    managed-starship = [ ".bashrc" ];
    managed-starship-zsh = [ ".zshrc" ];
  };

  # the option's entries: one per (id, target) pair
  fragmentEntries = lib.concatMap
    (f: map (target: {
      inherit target;
      id = f.id;
      marker = f.marker;
      payload = f.payload;
    }) fragmentTargets.${f.id})
    fragments;

  # the starship config payload, co-located beside this module (the
  # dissolved prompt capability's bytes live with their owner)
  starshipToml = ./starship.toml;

  # the hsql agent skill: generated from the installed derivation by the
  # tool's own --skill generator (the hsql precedent — a tool that ships
  # one serves its skill version-matched, offline, from the store). The
  # generator decides file-vs-dir by the target's existence, so the build
  # stages into a pre-created dir and copies out — one shape, always.
  hsqlSkill = pkgs.runCommand "hsql-agent-skill-${pkgs.harlequin.version}"
    {
      nativeBuildInputs = [ pkgs.harlequin ];
      passthru.version = pkgs.harlequin.version;
    }
    ''
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME" "$TMPDIR/skill"
      hsql --skill -o "$TMPDIR/skill"
      mkdir -p "$out"
      cp -a "$TMPDIR/skill/." "$out/"
    '';
in
{
  options.workstation.foundation = {
    tailscale.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        The fleet transport (ssh, the dashboard's --host binding, all host
        convergence ride it). The system legs declare services.tailscale
        through the system module; the host's MagicDNS name comes from
        workstation.host.tailscale.fqdn.
      '';
    };
    tailscale.acceptDns = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Accept the tailnet's DNS settings on the transport. Declared per
        host; the wiring lands with the first transport module that carries
        the option (the NixOS module integrates the tailnet DNS on enable).
      '';
    };
  };

  config = {
    # the shell lane: this domain's fragments in the declared order
    workstation.shell.fragments = fragmentEntries;

    home.file = {
      ".config/starship.toml".source = starshipToml;
      ".local/bin/rg".source = "${tools.rg}/rg";
      ".local/bin/fd".source = "${tools.fd}/fd";
      ".local/bin/fzf".source = "${tools.fzf}/fzf";
      ".local/bin/lazygit".source = "${tools.lazygit}/lazygit";
      ".local/bin/tree-sitter".source = "${tools.tree-sitter}/tree-sitter";
    };

    home.packages = [
      # the dissolved prompt capability: eza is the managed ls (icons),
      # starship the cross-shell prompt — both nixpkgs-native
      pkgs.eza
      pkgs.starship
      # harlequin + hsql: one upstream distribution (the terminal SQL IDE
      # and its headless agent CLI share adapters, config and engine). The
      # pinned nixpkgs (25.05) predates hsql — the version rides the
      # flake's pin-override overlay; the floor makes an unapplied overlay
      # die loudly here instead of quietly shipping a hsql-less IDE.
      (assert
        lib.versionAtLeast (pkgs.harlequin.version or "0") "2.9"
        || throw
          "workstation-foundation: pkgs.harlequin ${
            pkgs.harlequin.version or "?"
          } predates hsql — the flake's overlays.default (the foundation domain's pin surface) must be applied (nixpkgs.overlays)";
        pkgs.harlequin)
      # the tailscale CLI on the home PATH (the daemon is the system
      # service on NixOS/darwin legs; tailscaled is the host-owned
      # prerequisite on any standalone leg)
    ] ++ lib.optionals config.workstation.foundation.tailscale.enable [ pkgs.tailscale ];

    # the hsql agent skill: the build-time-generated tree (above), served
    # as a declared entry symlink by the agent module — the activation
    # copy provision retired with the copy contract
    programs.hermes.skills.hsql = {
      enable = true;
      source = hsqlSkill;
    };
  };
}
