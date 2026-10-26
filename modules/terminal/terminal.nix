# The terminal domain: tmux + nunchux — natively declared
# (docs/absorption.md). The tmux plugin checkouts and the nunchux checkout
# are fetchGit-pinned from the module's OWN declared pin data (one pin, one
# owner, one surface — the checkout pins live here, never in a shared
# file), deployed as store tree claims at the managed plugin root. The
# same declaration deploys as the pin manifest `.tmux/plugins.pins.json` —
# the verify lane's only anchor (the deployed pin, never a repo file — the
# agent domain's law). The nunchux `.platform` marker composes INTO the
# checkout (immutable store cannot host a file inside a dir symlink — the
# claim composition), and its theme-slot launcher config renders natively:
# slot substitution from tokens.lua through the theme extraction, asserted
# unresolved-slot-free. The managed binaries (tmux, the btop popup) come
# from nixpkgs on the system legs — the mise lane retired with the
# manifest. The stale tmux2k theme path retires through the declared
# retire list. Nunchux is linux-only (its supported_hosts contract,
# carried over as a platform gate).
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

  # the checkout pins: dir name -> url + rev, the terminal domain's
  # declared surface. tpm leads by deployment — it must exist before the
  # first tmux start (the run-shell at the end of .tmux.conf sources it);
  # store closure is order-free, the conf's own ordering is the contract.
  pluginPins = {
    "tpm" = {
      url = "https://github.com/tmux-plugins/tpm";
      rev = "e261deb1b47614eed3400089ce7197dc68acc4eb";
    };
    "tmux2k" = {
      url = "https://github.com/2KAbhishek/tmux2k";
      rev = "d8c5c2924c557835f984dd44eb71315b897bc4f5";
    };
    "tmux-yank" = {
      url = "https://github.com/tmux-plugins/tmux-yank";
      rev = "acfd36e4fcba99f8310a7dfb432111c242fe7392";
    };
    "tmux-resurrect" = {
      url = "https://github.com/tmux-plugins/tmux-resurrect";
      rev = "cff343cf9e81983d3da0c8562b01616f12e8d548";
    };
    "vim-tmux-navigator" = {
      url = "https://github.com/christoomey/vim-tmux-navigator";
      rev = "e41c431a0c7b7388ae7ba341f01a0d217eb3a432";
    };
  };
  plugins = builtins.mapAttrs (_: pin: builtins.fetchGit { inherit (pin) url rev; }) pluginPins;

  # nunchux: the checkout pin + the repo-tracked linux build's sha (the
  # verify lane's content pin) + the release the rev carries. The
  # release-asset checksum rows of the old inventory retired with it — no
  # build consumer (the `.platform` marker keeps upstream's ensure_binary
  # off the unchecksummed release fetches).
  nunchuxPin = {
    url = "https://github.com/datamadsen/nunchux";
    rev = "1546eaa980d834c331496ea9d51942be07ea9fdd";
    version = "3.1.3";
    repo_linux_amd64_sha256 = "8a6e46d937ee76ac6a483865c800de9208aabbe1dbc620473eb5e6b7d86b7b14";
  };

  # nunchux: the pinned checkout with the .platform marker composed in
  # (with it present, upstream's ensure_binary never fetches
  # releases/latest unchecksummed)
  nunchuxTree = pins.compose (builtins.fetchGit { inherit (nunchuxPin) url rev; }) [
    {
      path = "bin/.platform";
      source = ./nunchux/files/.tmux/plugins/nunchux/bin/.platform;
    }
  ];

  # the pin manifest: the declared pins, deployed beside the checkouts —
  # the verify lane's only anchor (verified against the DEPLOYED pin,
  # never a repo file)
  pinsManifest = builtins.toJSON {
    plugins = pluginPins;
    nunchux = nunchuxPin;
  };

  # the theme-slot launcher config, rendered natively: the template's slot
  # references substitute from the extracted tokens (byte-equal to
  # upstream's default config — only the two slot references carry the
  # theme rebrand)
  nunchuxConfig = theme.assertNoUnresolved
    (theme.renderSlots
      (builtins.readFile ./nunchux/files/.config/nunchux/config));
in
{
  config = {
    home.file = lib.mkMerge (
      [
        # the managed config: the payload file, and the XDG link to it
        # (intra-home — the walker's mkOutOfStoreSymlink shape, declared)
        {
          ".tmux.conf".source = ./tmux/files/.tmux.conf;
          ".config/tmux/tmux.conf".source = config.lib.file.mkOutOfStoreSymlink
            "${config.home.homeDirectory}/.tmux.conf";
          ".tmux/plugins.pins.json".text = pinsManifest + "\n";
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

