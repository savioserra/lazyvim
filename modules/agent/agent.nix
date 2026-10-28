# The agent domain: hermes (runtime pin, launcher, skills, extensions)
# and herdr. Hot-home owners: the pinned checkout
# (~/.hermes/hermes-agent - clone/fetch only when absent or clean-and-
# behind; dirty or runtime-advanced trees are never touched; a failed git
# step defers with a named receipt). The deployed pin manifest
# (.local/opt/hermes/pin.json) is the verify lane's only anchor.
#
# skills: one entry symlink per skill per target profile; the skills
# PARENT stays hot (hermes seeds its bundled skills there) - a declared
# name shadows a bundled one (asserted at eval). extensions: gateway
# plugin trees as derivations, entry-linked into ~/.hermes/plugins.
# Skill payloads are never copied into hot home.
#
# The interpreter is pkgs.python314, floored at the release the pinned
# rev's pm/lock.json carries (loud eval on mismatch). herdr has no
# nixpkgs coverage: one download pin, inline below.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  hermes = config.programs.hermes;

  # the runtime pin: the agent domain's own declared data (owner/repo/rev
  # + the hermetic hash - one pin, one owner, one surface). The tree feeds
  # the interpreter floor's lock read; it never enters the closure.
  hermesRev = "b23600860f82bd66d345c0a1baefd0f264605955";
  hermesTree = pkgs.fetchFromGitHub {
    owner = "NousResearch";
    repo = "hermes-agent";
    rev = hermesRev;
    hash = "sha256-RSsNOW1WqtaxORPVkUyXnUzIjOEjx7Vzvx49HQsue8A=";
  };
  hermesPin = {
    url = "https://github.com/NousResearch/hermes-agent";
    rev = hermesRev;
    tree = hermesTree;
  };

  # the interpreter's version floor: the release the pinned hermes rev's
  # pm/lock.json names (packages.python.version — "3.14.7+<buildtag>"; the
  # semver prefix is the floor). Read from the pinned tree so a hermes rev
  # bump re-derives the floor at eval — the eval dies naming both versions
  # when the nixpkgs set (via the flake's pin-override overlay) lags.
  lockedPythonVersion =
    if hermes.pin == null then
      null
    else
      let
        lock = builtins.fromJSON (builtins.readFile (hermes.pin.tree + "/pm/lock.json"));
        locked =
          lock.packages.python.version
            or (throw "workstation-agent: the pinned hermes rev's pm/lock.json carries no packages.python entry — the interpreter floor cannot be derived");
      in
      builtins.head (lib.splitString "+" locked);

  hermesPython =
    assert
      lockedPythonVersion == null
      || lib.versionAtLeast pkgs.python314.version lockedPythonVersion
      || throw "workstation-agent: pkgs.python314 ${pkgs.python314.version} predates the release the pinned hermes rev's pm/lock.json carries (${lockedPythonVersion}) — the flake's overlays.default (the foundation domain's pin surface) must be applied (nixpkgs.overlays), or the hermes-agent rev must move to a lock the nixpkgs set satisfies";
    pkgs.python314;

  # herdr keeps a download pin: no nixpkgs coverage (upstream ships
  # release binaries only — no package in either pinned nixpkgs set), so
  # it stays the substrate's ONE download pin, inline in its owning
  # module (one pin, one owner, one surface — a bump moves these rows and
  # the consumer together). Archive-less: the fetched bytes ARE the
  # binary.
  herdrVersion = "0.9.0";
  herdrPin =
    if pkgs.stdenv.hostPlatform.isx86_64 && pkgs.stdenv.hostPlatform.isLinux then
      {
        url = "https://github.com/herdrdev/herdr/releases/download/v${herdrVersion}/herdr-linux-x86_64";
        sha256 = "4fa1a01158dd8043da92d31b270780b0dcc10603038d9b61cac4d81ab63fb71f";
      }
    else if pkgs.stdenv.hostPlatform.isAarch64 && pkgs.stdenv.hostPlatform.isDarwin then
      {
        url = "https://github.com/herdrdev/herdr/releases/download/v${herdrVersion}/herdr-macos-aarch64";
        sha256 = "32b53df09872628059c789a69f02a6b8e29e14ddf26711421f3463f70c1aef17";
      }
    else
      throw "workstation-agent: no herdr release asset declared for system '${pkgs.system}' (the pin knows linux x86_64 and darwin arm64)";
  herdr =
    pkgs.runCommand "herdr-${herdrVersion}"
      {
        src = pkgs.fetchurl herdrPin;
        passthru.pinVersion = herdrVersion;
      }
      ''
        install -Dm755 "$src" "$out/bin/herdr"
      '';

  launcher =
    pkgs.runCommand "ws-hermes-launcher" { }
      # the payload lands 0644 in git; the launcher is a PATH entry, so the
      # store copy carries the executable bit (the old envelope's
      # `executable: true`, native)
      ''
        install -Dm755 ${./files/hermes-launcher.sh} "$out/hermes-launcher"
      '';

  # the deployed pin manifest: the verify lane's only anchor (the checkout
  # HEAD and the interpreter are verified against the DEPLOYED pin, never a
  # repo file). Null-safe on the pin: a null pin deploys an empty engine
  # row and the module's assertion fires the friendly message — the eval
  # never dies on a type error first.
  pinJson = builtins.toJSON {
    engine = {
      url = if hermes.pin != null then hermes.pin.url else "";
      rev = if hermes.pin != null then hermes.pin.rev else "";
    };
    python = pkgs.python314.version;
  };

  # the agent's authored skills: the single source both this module (the
  # option setters) and the flake's hermesSkills output import — each tree
  # serves as ONE entry symlink per target profile (the rendering lane
  # lives in nix/modules/workstation-options.nix, so the report fold
  # attributes every entry to the capability that set it)
  authoredSkills = import ./skills.nix { inherit self; };
in
{
  options.programs.hermes = {
    # the runtime pin: the flake input's fetchGit rev, surfaced per
    # capability. Unset means the agent domain serves no runtime: an eval
    # that reads hermes surfaces without a pin fails loudly with the name
    # of the missing flake output.
    pin = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            url = lib.mkOption {
              type = lib.types.str;
              description = "The hermes-agent upstream git URL (the clone surface).";
            };
            rev = lib.mkOption {
              type = lib.types.str;
              description = "The pinned hermes-agent commit.";
            };
            tree = lib.mkOption {
              type = lib.types.raw;
              description = ''
                The pinned tree as the caller's flake input value — build-time
                assertions read it; it never enters the deployed closure.
              '';
            };
          };
        }
      );
      default = hermesPin;
      defaultText = lib.literalExpression "hermesPin";
      description = ''
        The hermes-agent runtime pin (upstream URL, pinned rev, pinned
        tree), declared by this module.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = launcher;
      defaultText = lib.literalExpression "launcher";
      description = ''
        The engine launcher derivation: resolves the pinned interpreter and
        the pinned checkout from $HOME at run time, fails closed when
        either is missing. Deployed at .local/opt/hermes/bin/hermes and on
        PATH as .local/bin/hermes.
      '';
    };
  };

  # the selection gate (workstation.agent.enable, nix/lib/selections.nix)
  # wraps this CONFIG block: the option DECLARATIONS above
  # (programs.hermes.pin/package) stay ungated so every composition that
  # loads the domain modules still carries them; disabled = the definitions
  # skip, never the files
  config = lib.mkIf config.workstation.agent.enable {
    # --- the eval-time contract --------------------------------------------
    assertions = [
      {
        assertion = hermes.pin != null;
        message =
          "programs.hermes.pin is unset — the flake must surface "
          + "`hermesAgentPin` (its pinned hermes-agent input: url, rev, "
          + "tree); see outputs.hermesAgentPin in flake.nix";
      }
    ]
    ++ map (name: {
      assertion = hermes.pin.tree == null || !builtins.pathExists (hermes.pin.tree + "/skills/${name}");
      message =
        "programs.hermes.skills.${name} collides with a skill the pinned "
        + "hermes-agent bundles — skills_sync owns that name at runtime "
        + "and would fight the declared entry symlink; rename the "
        + "declared skill";
    }) (builtins.attrNames (lib.filterAttrs (_: skill: skill.enable) hermes.skills));

    # --- the agent's authored skills + the runtime stack --------------------
    # (the skill ENTRY rendering lives in nix/modules/workstation-options.nix
    # — the cross-capability lane — so the report fold attributes every
    # entry to the capability that set it)
    programs.hermes.skills = lib.mapAttrs (_: source: {
      enable = true;
      inherit source;
    }) authoredSkills;

    home.file = {
      # the pinned interpreter tree the launcher resolves at run time
      # (pkgs.python314, floored at the locked release — see above)
      ".local/opt/hermes/python".source = hermesPython;
      # the pin manifest: the verify lane's anchor (the deployed pin,
      # never a repo file)
      ".local/opt/hermes/pin.json".text = pinJson;
      # the engine launcher: the payload file at its runtime home...
      ".local/opt/hermes/bin/hermes".source = "${hermes.package}/hermes-launcher";
      # ...and the PATH entry — the store path links directly, no
      # ../opt indirection
      ".local/bin/hermes".source = "${hermes.package}/hermes-launcher";
      # herdr: the one download pin, the same direct store-path link
      ".local/bin/herdr".source = "${herdr}/bin/herdr";
    };

    # --- the pinned checkout (hot home; activation-managed) ----------------
    home.activation.ensure-hermes-checkout = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      url=${lib.escapeShellArg (if hermes.pin != null then hermes.pin.url else "")}
      rev=${lib.escapeShellArg (if hermes.pin != null then hermes.pin.rev else "")}
      checkout="$HOME/.hermes/hermes-agent"
      if [ -z "$rev" ]; then
        echo "workstation: hermes checkout ensure deferred — programs.hermes.pin is unset (the module's assertion names the fix)"
      elif ! command -v git >/dev/null 2>&1; then
        echo "workstation: hermes checkout ensure deferred — git unavailable on PATH"
      elif [ ! -d "$checkout/.git" ]; then
        if git clone --quiet "$url" "$checkout" && git -C "$checkout" checkout --quiet --detach "$rev"; then
          echo "workstation: hermes checkout cloned at the pinned commit $rev"
        else
          echo "workstation: hermes checkout ensure deferred — clone failed (offline or unreachable)"
        fi
      else
        head=$(git -C "$checkout" rev-parse HEAD 2>/dev/null || true)
        dirty=$(git -C "$checkout" status --porcelain 2>/dev/null | head -n 1)
        if [ -n "$dirty" ]; then
          echo "workstation: hermes checkout dirty — runtime state untouched"
        elif [ "$head" = "$rev" ]; then
          echo "workstation: hermes checkout already at the pinned commit"
        elif git -C "$checkout" merge-base --is-ancestor "$head" "$rev" 2>/dev/null; then
          if git -C "$checkout" fetch --quiet origin "$rev" && git -C "$checkout" checkout --quiet --detach "$rev"; then
            echo "workstation: hermes checkout fetched to the pinned commit $rev"
          else
            echo "workstation: hermes checkout ensure deferred — fetch failed (offline or unreachable)"
          fi
        else
          echo "workstation: hermes checkout runtime-advanced ($head) — untouched"
        fi
      fi
    '';

    # --- the domain's tombstone --------------------------------------------
    workstation.retire = [ ".hermes/skills/lazyvim/SKILL.md" ];
  };
}
