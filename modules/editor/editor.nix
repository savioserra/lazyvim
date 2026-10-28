# The editor domain: the nvim payload, the nixpkgs neovim, and the composed
# language profile — natively declared (docs/absorption.md, "The nvim-profile
# gap this design closes").
#
# What the walker's nvim-profile lane never did — deploy the composed
# profile.lua — this module does:
#   - the static config payload deploys as one recursive home.file tree
#     (everything under nvim/files/.config/nvim — the payload co-located
#     beside this module
#     EXCEPT lazy-lock.json — the lock is runtime-extended application state
#     and is never byte-compared);
#   - profile.lua composes from the language entries the editor and the
#     language modules declare (workstation.editor.languages) via
#     lib.generators.toLua, landing at lua/languages/profile.lua inside the
#     same tree — the gap the design closes;
#   - each language's custom plugin module deploys beside the profile
#     (workstation.editor.languagePlugins);
#   - the behavior cases (language_cases/formatter_cases) stay payload data
#     — they feed the verify lane, not the deployed file;
#   - the lazy-lock merge is the payload's merge program promoted to module
#     implementation: the pinned baseline seeds an absent lock through the
#     deployed nvim; a drifted lock reconciles (engine pins win, host
#     extras with an installed plugin dir preserved, stale extras pruned)
#     and is never reset;
#   - .local/bin/nvim is the nixpkgs neovim — the store path links directly.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  # the editor's neovim, floored at the retired download pin's version
  # (0.12.4): the overlay supplies the foundation set's prebuilt closure
  # (self-consistent — foundation's neovim compiles against foundation's
  # tree-sitter), so the workstation's nvim never drops below the pin line
  nvim =
    assert
      lib.versionAtLeast (pkgs.neovim.version or "0") "0.12"
      || throw "workstation-editor: neovim ${pkgs.neovim.version or "?"} predates the retired pin floor 0.12 — the flake's overlays.default must carry the foundation set's neovim";
    pkgs.neovim;
  cfg = config.workstation.editor;

  payloadNvim = ./nvim/files/.config/nvim;
  modifyTemplate = ./nvim/files/modify/lazy-lock.json.sh;
  lazyLockBaseline = payloadNvim + "/lazy-lock.json";

  # the profile's base entry: the editor's own standard composition (the
  # nvim manifest's `standard` entry — the cases stay payload data)
  standardEntry = {
    id = "standard";
    lazyvim_extras = [
      "lazyvim.plugins.extras.lang.docker"
      "lazyvim.plugins.extras.lang.json"
      "lazyvim.plugins.extras.lang.markdown"
      "lazyvim.plugins.extras.lang.tailwind"
      "lazyvim.plugins.extras.lang.toml"
      "lazyvim.plugins.extras.lang.yaml"
    ];
  };

  # collection order: id sort — deterministic bytes, reviewed in diffs
  # (the old graph walk's tie-break, promoted to the declared order)
  entries = lib.sort (a: b: a.id < b.id) ([ standardEntry ] ++ cfg.languages);

  # the file is a lua MODULE: it must RETURN the table (a bare table
  # literal is not a valid chunk — nvim dies with E5113 on require)
  profileLua =
    "return " + lib.generators.toLua { } (map (e: lib.filterAttrs (_: v: v != null) e) entries) + ";";

  # the merge program: the modify template's lua body (the heredoc between
  # the `cat >` line and the exact-match closing delimiter) with the
  # baseline embedded at its marker — the marker carries exactly once, the
  # embed contract the engine enforced
  mergeLua =
    let
      lines = lib.splitString "\n" (builtins.readFile modifyTemplate);
      start =
        lib.lists.findFirstIndex
          (l: lib.hasPrefix "cat >" l && lib.hasSuffix "<<'__WORKSTATION_LAZY_LOCK_LUA__'" l)
          (throw "workstation-editor: the lazy-lock modify template's heredoc declaration is missing")
          lines;
      end = lib.lists.findFirstIndex (
        l: l == "__WORKSTATION_LAZY_LOCK_LUA__"
      ) (throw "workstation-editor: the lazy-lock modify template's heredoc delimiter is missing") lines;
    in
    assert
      end > start + 1
      || throw "workstation-editor: the lazy-lock modify template's heredoc body is empty";
    builtins.replaceStrings [ "__WORKSTATION_ENGINE_PINS__" ] [ (builtins.readFile lazyLockBaseline) ] (
      lib.concatStringsSep "\n" (lib.sublist (start + 1) (end - start - 1) lines)
    );

  mergeProgram = pkgs.writeText "ws-lazy-lock-merge.lua" mergeLua;

  # the static config tree: the payload minus the lock, plus the composed
  # profile and the language plugin modules
  configTree = pkgs.runCommand "ws-editor-nvim-config" { } ''
    set -euo pipefail
    mkdir -p "$out"
    cp -a ${payloadNvim}/. "$out/"
    chmod -R u+w "$out"
    # the lock is runtime-extended application state — the tree never
    # carries it; the merge activation seeds the live copy
    rm -f "$out/lazy-lock.json"
    mkdir -p "$out/lua/languages/plugins"
    cp ${pkgs.writeText "languages-profile.lua" profileLua} "$out/lua/languages/profile.lua"
    ${lib.concatMapStringsSep "\n" (
      p: ''cp -a "${p}" "$out/lua/languages/plugins/$(basename "${p}")"''
    ) cfg.languagePlugins}
  '';
in
{
  # the language surface is DECLARED in workstation-options.nix (the
  # cross-capability contract: the language capabilities set it, this module
  # composes it into the deployed profile)

  # the selection gate (workstation.editor.enable, nix/lib/selections.nix):
  # disabled = the definitions skip, never the files — the walk, the fold
  # and the retire lists stay complete
  # the parser-install CLI the editor's tooling drives
  home.packages = [ pkgs.workstation-tree-sitter ];

  config = lib.mkIf cfg.enable {
    home.file = {
      ".config/nvim" = {
        source = configTree;
        recursive = true;
      };
      # the nixpkgs neovim on PATH — the nvim-profile lane's bin override,
      # now the declaration itself (the bootstrap archive pin is retired)
      ".local/bin/nvim".source = "${nvim}/bin/nvim";
    };

    # the lock merge: seed an absent lock from the pinned baseline,
    # reconcile a drifted one (engine pins win, installed host extras
    # preserved) — never a byte-compare, never a reset of runtime drift
    home.activation.merge-lazy-lock = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      lock="$HOME/.config/nvim/lazy-lock.json"
      work=$(mktemp)
      trap 'rm -f "$work"' EXIT
      cp ${mergeProgram} "$work"
      if [ -f "$lock" ]; then
        ${nvim}/bin/nvim -l "$work" < "$lock" > "$lock.merged"
      else
        ${nvim}/bin/nvim -l "$work" < /dev/null > "$lock.merged"
      fi
      mv "$lock.merged" "$lock"
      echo "workstation: lazy-lock merge applied (${config.home.homeDirectory}/.config/nvim/lazy-lock.json)"
    '';
  };
}
