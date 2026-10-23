# The agent domain: hermes and herdr, natively declared (docs/absorption.md
# — the copy/git-into-.hermes/remove refusal lanes close here).
#
# Three hot-home surfaces, exactly per the design's mapping:
#   skills            — declared skill LEAVES as store-path home.file
#                       entries (recursive: real dirs, per-file store
#                       links; the agent consumes them read-only and an
#                       in-place edit is replaced at the next switch —
#                       declared truth wins). The skills PARENT stays hot:
#                       the agent's runtime-mutated state is never tracked.
#   the checkout      — home.activation ensure: idempotent clone/fetch to
#                       the hermes_agent pin ONLY when the checkout is
#                       absent or clean-and-behind; a dirty or
#                       runtime-advanced tree is never touched. Activation
#                       scripts mutate hot state; the file plane never
#                       tracks it. A failed git step defers with a named
#                       receipt (the checkout is the one network surface;
#                       the hermes verify lane is the contract that catches
#                       real drift on converged hosts).
#   the retire list   — the substrate's declared tombstones (see
#                       workstation.retire in workstation-home.nix); this
#                       domain declares .hermes/skills/lazyvim/SKILL.md.
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
  cfg = config.workstation.agent;

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
      install -Dm755 ${self + "/workstation/packages/agent/files/hermes-launcher.sh"} "$out/hermes-launcher"
    '';
in
{
  options.workstation.agent = {
    skills = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = import ./skills.nix { inherit self; };
      defaultText = lib.literalExpression "import ./skills.nix { inherit self; }";
      description = ''
        The agent's managed skills: skill name -> payload dir. Each skill
        leaf renders as a store-path home.file entry (recursive), so HM
        manages exactly the declared leaves while the rest of ~/.hermes
        stays hot.
      '';
    };
  };

  config = {
    # --- the declared skill leaves -----------------------------------------
    home.file = lib.mkMerge (
      lib.mapAttrsToList
        (name: dir: {
          ".hermes/skills/${name}" = {
            source = dir;
            recursive = true;
          };
        })
        cfg.skills
      ++ [
        # --- the runtime stack ---------------------------------------------
        {
          # the pinned interpreter tree the launcher resolves at run time
          ".local/opt/hermes/python".source = hermesPython;
          # the engine launcher: the payload file at its runtime home...
          ".local/opt/hermes/bin/hermes".source = "${launcher}/hermes-launcher";
          # ...and the PATH entry — the store path links directly, no
          # ../opt indirection
          ".local/bin/hermes".source = "${launcher}/hermes-launcher";
          # herdr: archive-less pin, the same direct store-path link
          ".local/bin/herdr".source = "${herdr}/bin/herdr";
        }
      ]
    );

    # --- the pinned checkout (hot home; activation-managed) ----------------
    home.activation.ensure-hermes-checkout = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      url=${lib.escapeShellArg pins.inventory."hermes_agent_git_url"}
      rev=${lib.escapeShellArg pins.inventory."hermes_agent_git_commit"}
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
