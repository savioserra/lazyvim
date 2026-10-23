# The terminal domain: tmux + nunchux — natively declared
# (docs/absorption.md). The tmux plugin checkouts and the nunchux checkout
# are fetchGit-pinned from the inventory (versions.json is the interim pin
# inventory; no pin is duplicated into module literals), deployed as store
# tree claims at the managed plugin root. The nunchux `.platform` marker
# composes INTO the checkout (immutable store cannot host a file inside a
# dir symlink — the claim composition), and its theme-slot launcher config
# renders natively: slot substitution from tokens.lua through the theme
# extraction, asserted unresolved-slot-free. The managed binaries (tmux,
# the btop popup) come from nixpkgs on the system legs — the mise lane
# retired with the manifest. The stale tmux2k theme path retires through
# the declared retire list. Nunchux is linux-only (its supported_hosts
# contract, carried over as a platform gate).
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  pins = import ../../nix/lib/pins.nix { inherit lib pkgs; };
  theme = import ../theme/theme.nix { inherit lib self; };

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

  # nunchux: the pinned checkout with the .platform marker composed in
  # (with it present, upstream's ensure_binary never fetches
  # releases/latest unchecksummed)
  nunchuxTree = pins.compose (pins.fetchGitPin "nunchux" { }) [
    {
      path = "bin/.platform";
      source =
        self + "/workstation/packages/terminal/nunchux/files/.tmux/plugins/nunchux/bin/.platform";
    }
  ];

  # the theme-slot launcher config, rendered natively: the template's slot
  # references substitute from the extracted tokens (byte-equal to
  # upstream's default config — only the two slot references carry the
  # theme rebrand)
  nunchuxConfig = theme.assertNoUnresolved
    (theme.renderSlots
      (builtins.readFile
        (self + "/workstation/packages/terminal/nunchux/files/.config/nunchux/config")));
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
      ++ lib.optionals pkgs.stdenv.isLinux [
        {
          ".tmux/plugins/nunchux".source = nunchuxTree;
          ".config/nunchux/config".text = nunchuxConfig;
        }
      ]
    );

    # the stale tmux2k theme path (the slot template the capability
    # retired) — the domain's tombstone
    workstation.retire = [ ".config/tmux/themes/tmux2k.conf" ];
  };
}

