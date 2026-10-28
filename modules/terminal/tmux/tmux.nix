# The tmux capability (terminal/tmux): the .tmux.conf payload, the XDG
# link, the pinned plugin checkouts, and the deployed pin manifest
# (docs/absorption.md). The plugin checkouts are fetchFromGitHub pins from
# the module's OWN declared pin data (one pin, one owner, one surface —
# owner/repo/rev/hash literals here, the hashed hermetic fetch — never a
# network-hungry fetchGit outside the lock). Deployed as store tree claims
# at the managed plugin root. The manifest renders from the terminal
# domain's declared pin rows (workstation.terminal.pins — the cross-member
# contract in nix/modules/workstation-options.nix): this capability
# contributes its plugin rows and renders the file, so the manifest is
# always exactly the rows of the checkouts that deployed beside it. The
# stale tmux2k theme path retires through the declared retire list.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # the checkout pins: dir name -> owner/repo/rev/hash, the capability's
  # declared surface (a bump moves the row, its hash and the consumer
  # together). tpm leads by deployment — it must exist before the first
  # tmux start (the run-shell at the end of .tmux.conf sources it); store
  # closure is order-free, the conf's own ordering is the contract.
  pluginPins = {
    "tpm" = {
      owner = "tmux-plugins";
      repo = "tpm";
      rev = "e261deb1b47614eed3400089ce7197dc68acc4eb";
      hash = "sha256-oRKUZNyJYQXlkeQfbEYiltUEBpvdwn2SoEBWHVUNmrA=";
    };
    "tmux2k" = {
      owner = "2KAbhishek";
      repo = "tmux2k";
      rev = "d8c5c2924c557835f984dd44eb71315b897bc4f5";
      hash = "sha256-++FpnS/N9OHGhWjnD/Q0Dhwd+S3wNRr7R9ArZKBwpwA=";
    };
    "tmux-yank" = {
      owner = "tmux-plugins";
      repo = "tmux-yank";
      rev = "acfd36e4fcba99f8310a7dfb432111c242fe7392";
      hash = "sha256-/5HPaoOx2U2d8lZZJo5dKmemu6hKgHJYq23hxkddXpA=";
    };
    "tmux-resurrect" = {
      owner = "tmux-plugins";
      repo = "tmux-resurrect";
      rev = "cff343cf9e81983d3da0c8562b01616f12e8d548";
      hash = "sha256-FcSjYyWjXM1B+WmiK2bqUNJYtH7sJBUsY2IjSur5TjY=";
    };
    "vim-tmux-navigator" = {
      owner = "christoomey";
      repo = "vim-tmux-navigator";
      rev = "e41c431a0c7b7388ae7ba341f01a0d217eb3a432";
      hash = "sha256-efqiRffnidYx+qjgsHyWshCFWgZp/ZrHl+Clt04pfpM=";
    };
  };
  plugins = builtins.mapAttrs (
    _: pin:
    pkgs.fetchFromGitHub {
      inherit (pin)
        owner
        repo
        rev
        hash
        ;
    }
  ) pluginPins;

  # the tmux reply drain: tmux asks the terminal its background colour at
  # startup (OSC 11); on a high-latency link the reply can cross the tty
  # restore and the shell echoes the tail (`11;rgb:...`) at the next
  # prompt. The wrapper drains that reply window after tmux returns -
  # bash and zsh variants (the rc lane's interactive shells). The order
  # slot is the terminal domain's own lane; other domains never see it.
  drainBash = pkgs.writeText "tmux-drain.bash" '''
    tmux() {
      command tmux "$@"
      local _rc=$?
      read -t 0.5 -r _ </dev/tty 2>/dev/null
      return $_rc
    }
  '';
  drainZsh = pkgs.writeText "tmux-drain.zsh" '''
    tmux() {
      command tmux "$@"
      local _rc=$?
      read -t 0.5 -r _ </dev/tty 2>/dev/null
      return $_rc
    }
  '';
in
{
  config = lib.mkIf (config.workstation.terminal.enable && config.workstation.terminal.tmux.enable) {
    # the tmux binary belongs to the capability that deploys its config
    # and plugins (the tool ships beside the surface it configures)
    home.packages = [ pkgs.tmux ];

    # the reply-drain wrappers ride the rc lane (bash + zsh), in the
    # terminal domain's own lane
    workstation.shell.fragments = [
      {
        target = ".bashrc";
        id = "tmux-drain";
        order = 10;
        domain = "terminal";
        marker = "# workstation: tmux reply drain";
        payload = drainBash;
      }
      {
        target = ".zshrc";
        id = "tmux-drain-zsh";
        order = 10;
        domain = "terminal";
        marker = "# workstation: tmux reply drain";
        payload = drainZsh;
      }
    ];

    # this capability's manifest rows (the nunchux capability contributes
    # its own when it deploys — the manifest renders the union)
    workstation.terminal.pins = builtins.mapAttrs (_: pin: {
      url = "https://github.com/${pin.owner}/${pin.repo}";
      inherit (pin) rev;
    }) pluginPins;

    home.file = lib.mkMerge (
      [
        # the managed config: the payload file, and the XDG link to it
        # (intra-home, declared)
        {
          ".tmux.conf".source = ./files/.tmux.conf;
          ".config/tmux/tmux.conf".source =
            config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/.tmux.conf";
          # the pin manifest: the declared rows (this capability's plugins
          # plus any member rows set beside it), deployed beside the
          # checkouts — the verify lane's only anchor (verified against the
          # DEPLOYED pin, never a repo file). Nulls drop: a plugin row
          # carries url and rev only.
          ".tmux/plugins.pins.json".text =
            builtins.toJSON (
              builtins.mapAttrs (_: row: lib.filterAttrs (_: v: v != null) row) config.workstation.terminal.pins
            )
            + "\n";
        }
      ]
      ++ lib.mapAttrsToList (name: tree: {
        ".tmux/plugins/${name}".source = tree;
      }) plugins
    );

    # the stale tmux2k theme path (the slot template the capability
    # retired) — the capability's tombstone
    workstation.retire = [ ".config/tmux/themes/tmux2k.conf" ];
  };
}
