# The base shell environment: the rc lane + fd, fzf, rg, lazygit,
# tree-sitter (checksummed pins), eza + starship (nixpkgs — the prompt
# capability dissolved here), mise (nixpkgs — the binary only, no managed
# footprint), harlequin + hsql (one upstream distribution;
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

  # the checksummed pins: the foundation domain's declared pin data — one
  # pin, one owner, one surface (the bump moves these rows and the
  # consumers together), rendered as store trees the bin links reach
  # directly
  tools = {
    rg = pins.tool "ripgrep" {
      version = "15.2.0";
      url = {
        linux_x86_64 = "https://github.com/BurntSushi/ripgrep/releases/download/{V}/ripgrep-{V}-x86_64-unknown-linux-musl.tar.gz";
        darwin_arm64 = "https://github.com/BurntSushi/ripgrep/releases/download/{V}/ripgrep-{V}-aarch64-apple-darwin.tar.gz";
      };
      sha256 = {
        linux_x86_64 = "33e15bcf1624b25cdd2a55813a47a2f95dbe126268203e76aa6a585d1e7b149c";
        darwin_arm64 = "3750b2e93f37e0c692657da574d7019a101c0084da05a790c83fd335bad973e4";
      };
      archive = "tar.gz";
      probe = {
        argv = [ "rg" "--version" ];
        # upstream prints the packaging rev beside the version (the release
        # identity's own suffix — moves with the pin on a bump)
        output = "ripgrep {V} (rev e89fff89ac)";
      };
    };
    fd = pins.tool "fd" {
      version = "10.4.2";
      url = {
        linux_x86_64 = "https://github.com/sharkdp/fd/releases/download/v{V}/fd-v{V}-x86_64-unknown-linux-gnu.tar.gz";
        darwin_arm64 = "https://github.com/sharkdp/fd/releases/download/v{V}/fd-v{V}-aarch64-apple-darwin.tar.gz";
      };
      sha256 = {
        linux_x86_64 = "def59805cd14b5651b68990855f426ad087f3b96881296d963910431ba3143c8";
        darwin_arm64 = "623dc0afc81b92e4d4606b380d7bc91916ba7b97814263e554d50923a39e480a";
      };
      archive = "tar.gz";
      probe = {
        argv = [ "fd" "--version" ];
        output = "fd {V}";
      };
    };
    fzf = pins.tool "fzf" {
      version = "0.74.2";
      url = {
        linux_x86_64 = "https://github.com/junegunn/fzf/releases/download/v{V}/fzf-{V}-linux_amd64.tar.gz";
        darwin_arm64 = "https://github.com/junegunn/fzf/releases/download/v{V}/fzf-{V}-darwin_arm64.tar.gz";
      };
      sha256 = {
        linux_x86_64 = "b3648f48675612b69ee35371cf6dc99ca96d767e89b912d079080916ac8ba8bd";
        darwin_arm64 = "d60ddb36356566ac69bae7c3504e888916cf747c9ad2132141c09229b1e28dee";
      };
      archive = "tar.gz";
      probe = {
        argv = [ "fzf" "--version" ];
        # upstream prints the build commit beside the version (the release
        # identity's own suffix — moves with the pin on a bump)
        output = "{V} (3337be9d)";
      };
    };
    lazygit = pins.tool "lazygit" {
      version = "0.63.1";
      url = {
        linux_x86_64 = "https://github.com/jesseduffield/lazygit/releases/download/v{V}/lazygit_{V}_linux_x86_64.tar.gz";
        darwin_arm64 = "https://github.com/jesseduffield/lazygit/releases/download/v{V}/lazygit_{V}_darwin_arm64.tar.gz";
      };
      sha256 = {
        linux_x86_64 = "8e033bc78c8e192dee9510e951f6c9e154289b7198d22c924ed1d0a951b0dac1";
        darwin_arm64 = "b963e9d0a1f4649708c594ac6c999cdcd435f8e679e220e78e87c4642badedd6";
      };
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
      version = "0.26.11";
      url = {
        linux_x86_64 = "https://github.com/tree-sitter/tree-sitter/releases/download/v{V}/tree-sitter-cli-linux-x64.zip";
        darwin_arm64 = "https://github.com/tree-sitter/tree-sitter/releases/download/v{V}/tree-sitter-cli-macos-arm64.zip";
      };
      sha256 = {
        linux_x86_64 = "ff1b7f9863f2faafd78dc0e66d902ee85b37f709b314b22c009f51caf233eebd";
        darwin_arm64 = "050f41d60a054b608ea392ba14722bba9457bdc0ab11a5706c77f034dafc68ac";
      };
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
      # mise (mise-en-place): the nixpkgs-native binary only — per-project
      # runtime versioning (`mise use`, `.mise.toml`, `mise x`) on every
      # managed host, the pin riding the nixpkgs lock. The engine owns
      # nothing around it: no managed MISE_DATA_DIR, no `.local/bin/mise`
      # launcher, no activation fragment — the retired managed-mise lane's
      # split-brain (t_1ae61704) stays structurally dead, and shell
      # activation (`mise activate`) is operator opt-in (its own card, if
      # ever — it shadows PATH tools).
      pkgs.mise
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
