# The terminal domain: tmux (and nunchux, landing next in the chain) —
# natively declared (docs/absorption.md). The five plugin checkouts are
# fetchGit-pinned from the inventory (versions.json is the interim pin
# inventory; no pin is duplicated into module literals), deployed as store
# tree claims at the managed plugin root. The managed binaries (tmux, the
# btop popup) come from nixpkgs on the system legs — the mise lane retired
# with the manifest. The stale tmux2k theme path retires through the
# declared retire list.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  pins = import ../../nix/lib/pins.nix { inherit lib pkgs; };

  # the plugin set: dir name -> inventory key. tpm leads by deployment —
  # it must exist before the first tmux start (the run-shell at the end of
  # .tmux.conf sources it); store closure is order-free, the conf's own
  # ordering is the contract.
  plugins = {
    "tpm" = pins.fetchGitPin "tpm" { };
    "tmux2k" = pins.fetchGitPin "tmux2k" { };
    "tmux-yank" = pins.fetchGitPin "tmux_yank" { };
    "tmux-resurrect" = pins.fetchGitPin "tmux_resurrect" { };
    "vim-tmux-navigator" = pins.fetchGitPin "vim_tmux_navigator" { };
  };
in
{
  config = {
    home.file = lib.mkMerge (
      [
        # the managed config: the payload file, and the XDG link to it
        # (intra-home — the walker's mkOutOfStoreSymlink shape, declared)
        {
          ".tmux.conf".source =
            self + "/workstation/packages/terminal/tmux/files/.tmux.conf";
          ".config/tmux/tmux.conf".source = config.lib.file.mkOutOfStoreSymlink
            "${config.home.homeDirectory}/.tmux.conf";
        }
      ]
      ++ lib.mapAttrsToList (name: tree: {
        ".tmux/plugins/${name}".source = tree;
      }) plugins
    );

    # the stale tmux2k theme path (the slot template the capability
    # retired) — the domain's tombstone
    workstation.retire = [ ".config/tmux/themes/tmux2k.conf" ];
  };
}
