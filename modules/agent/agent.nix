# The agent domain: hermes and herdr, fully declarative (LM1 —
# docs/absorption.md's copy/git-into-.hermes lanes close here under
# programs.hermes).
#
# The hot-home surfaces and their owners:
#   the runtime pin   — programs.hermes.pin: the flake input's fetchGit rev
#                       (outputs.hermesAgentPin, framed per capability as
#                       inputs.hermes-agent). The pinned checkout stays hot
#                       home — hermes' update machinery, pm store and
#                       recovery closures write into the tree — so the pin
#                       owns WHERE the checkout points and the activation
#                       ensure owns moving it: clone/fetch only when absent
#                       or clean-and-behind; a dirty or runtime-advanced
#                       tree is never touched. A failed git step defers with
#                       a named receipt (the checkout is the one network
#                       surface; the verify lane catches real drift on
#                       converged hosts). The deployed pin manifest
#                       (.local/opt/hermes/pin.json) is the verify lane's
#                       only anchor — the deployed pin, never a repo file.
#   skills            — programs.hermes.skills: ONE entry symlink per skill
#                       per target profile (default = ~/.hermes/skills, a
#                       named profile = ~/.hermes/profiles/<name>/skills).
#                       The entry is atomic — a switch replaces the whole
#                       skill, an in-place edit fails on the read-only store
#                       (declared truth wins, loudly) — while the skills
#                       PARENT stays hot: skills_sync seeds and updates
#                       hermes' bundled skills there, the curator archives
#                       there, and none of them ever write into a declared
#                       name (a build-time assertion refuses a name the
#                       pinned tree bundles).
#   extensions        — programs.hermes.extensions: gateway plugin trees as
#                       derivations (the python-env pattern), linked as
#                       entry symlinks into ~/.hermes/plugins — user
#                       discovery outranks bundled, so a declared extension
#                       shadows a same-named bundled plugin; per-plugin
#                       enablement stays live state (hermes plugins enable).
#
# The copy contract is retired: skill payloads are never copied or
# per-file-linked into hot home — the declared entry symlink is the whole
# surface. Adopt is explicit: a pre-link activation step makes way for the
# first generation's symlinks by removing the copy-contract trees (real
# dirs only, named receipt), then HM links the store entries.
#
# The runtime stack stays pinned: the hermes interpreter at
# .local/opt/hermes/python (a store tree the launcher resolves at run
# time) and the engine launcher on PATH — the store path links directly,
# no ../opt indirection. herdr is an archive-less pin linked the same way.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  hermes = config.programs.hermes;

  pins = import ../../nix/lib/pins.nix { inherit lib pkgs; };

  # the runtime pins (versions.json is the interim inventory)
  hermesPython = pins.tool "hermes_python" {
    archive = "tar.gz";
    layout = "release";
    probe = {
      argv = [ "bin/python3" "--version" ];
      output = "Python {V}";
    };
  };
  herdr = pins.tool "herdr" { };

  launcher = pkgs.runCommand "ws-hermes-launcher" { }
    # the payload lands 0644 in git; the launcher is a PATH entry, so the
    # store copy carries the executable bit (the old envelope's
    # `executable: true`, native)
    ''
      install -Dm755 ${./files/hermes-launcher.sh} "$out/hermes-launcher"
    '';

  # the deployed pin manifest: the verify lane's only anchor (the checkout
  # HEAD and the interpreter are verified against the DEPLOYED pin, never a
  # repo file)
  pinJson = builtins.toJSON {
    engine = {
      inherit (hermes.pin) url rev;
    };
    python = pins.inventory."hermes_python";
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
      type = lib.types.nullOr (lib.types.submodule {
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
      });
      default = if self ? hermesAgentPin then self.hermesAgentPin else null;
      defaultText = lib.literalExpression "self.hermesAgentPin";
      description = ''
        The hermes-agent runtime pin (upstream URL, pinned rev, pinned
        tree). The flake surfaces it as outputs.hermesAgentPin from its
        inputs.hermes-agent.
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

  config = {
    # --- the eval-time contract --------------------------------------------
    assertions = [
      {
        assertion = hermes.pin != null;
        message =
          "programs.hermes.pin is unset — the flake must surface "
          + "`hermesAgentPin` (its pinned hermes-agent input: url, rev, "
          + "tree); see outputs.hermesAgentPin in flake.nix";
      }
    ] ++ map
      (name: {
        assertion =
          hermes.pin.tree == null
          || !builtins.pathExists (hermes.pin.tree + "/skills/${name}");
        message =
          "programs.hermes.skills.${name} collides with a skill the pinned "
          + "hermes-agent bundles — skills_sync owns that name at runtime "
          + "and would fight the declared entry symlink; rename the "
          + "declared skill";
      })
      (builtins.attrNames (lib.filterAttrs (_: skill: skill.enable) hermes.skills));

    # --- the agent's authored skills + the runtime stack --------------------
    # (the skill ENTRY rendering lives in nix/modules/workstation-options.nix
    # — the cross-capability lane — so the report fold attributes every
    # entry to the capability that set it)
    programs.hermes.skills = lib.mapAttrs
      (_: source: {
        enable = true;
        inherit source;
      })
      authoredSkills;

    home.file = {
      # the pinned interpreter tree the launcher resolves at run time
      ".local/opt/hermes/python".source = hermesPython;
      # the pin manifest: the verify lane's anchor (the deployed pin,
      # never a repo file)
      ".local/opt/hermes/pin.json".text = pinJson;
      # the engine launcher: the payload file at its runtime home...
      ".local/opt/hermes/bin/hermes".source = "${hermes.package}/hermes-launcher";
      # ...and the PATH entry — the store path links directly, no
      # ../opt indirection
      ".local/bin/hermes".source = "${hermes.package}/hermes-launcher";
      # herdr: archive-less pin, the same direct store-path link
      ".local/bin/herdr".source = "${herdr}/bin/herdr";
    };

    # --- the pinned checkout (hot home; activation-managed) ----------------
    home.activation.ensure-hermes-checkout = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      url=${lib.escapeShellArg hermes.pin.url}
      rev=${lib.escapeShellArg hermes.pin.rev}
      checkout="$HOME/.hermes/hermes-agent"
      if ! command -v git >/dev/null 2>&1; then
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
