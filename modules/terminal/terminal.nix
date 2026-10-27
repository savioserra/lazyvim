# The terminal domain: tmux + nunchux — natively declared
# (docs/absorption.md). The tmux plugin checkouts and the nunchux checkout
# are fetchFromGitHub pins from the module's OWN declared pin data (one
# pin, one owner, one surface — owner/repo/rev/hash literals here, the
# hashed hermetic fetch — never a network-hungry fetchGit outside the
# lock). Deployed as store tree claims at the managed plugin root. The
# same declaration deploys as the pin manifest `.tmux/plugins.pins.json` —
# the verify lane's only anchor (the deployed pin, never a repo file —
# the agent domain's law). The nunchux `.platform` marker composes INTO
# the checkout (immutable store cannot host a file inside a dir symlink —
# the claim composition is a tiny local derivation), and its theme-slot
# launcher config renders natively: slot substitution from tokens.lua
# through the theme extraction, asserted unresolved-slot-free. The managed
# binaries (tmux, the btop popup) come from nixpkgs on the system legs —
# the mise lane retired with the manifest. The stale tmux2k theme path
# retires through the declared retire list. Nunchux is linux-only (its
# supported_hosts contract, carried over as a platform gate).
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  theme = import ../theme/theme.nix { inherit lib self; };

  # the checkout pins: dir name -> owner/repo/rev/hash, the terminal
  # domain's declared surface (a bump moves the row, its hash and the
  # consumer together). tpm leads by deployment — it must exist before the
  # first tmux start (the run-shell at the end of .tmux.conf sources it);
  # store closure is order-free, the conf's own ordering is the contract.
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

  # nunchux: the checkout pin + the repo-tracked linux build's sha (the
  # verify lane's content pin) + the release the rev carries. The
  # release-asset checksum rows of the old inventory retired with it — no
  # build consumer (the `.platform` marker keeps upstream's ensure_binary
  # off the unchecksummed release fetches).
  nunchuxPin = {
    owner = "datamadsen";
    repo = "nunchux";
    rev = "1546eaa980d834c331496ea9d51942be07ea9fdd";
    hash = "sha256-C7sXigf8qB5umoZSU8nsqj6vPdd8NMhmTg8B64rysUw=";
    version = "3.1.3";
    repo_linux_amd64_sha256 = "8a6e46d937ee76ac6a483865c800de9208aabbe1dbc620473eb5e6b7d86b7b14";
  };

  # the claim composition: children (files or whole trees) overlay INTO
  # the base tree — immutable store cannot host a file inside a dir
  # symlink, so the composed tree is one derivation. One consumer left
  # after the pins machinery retired (nvm's nested-node claim went with
  # it), so the HOW lives inline here — the pins library stays retired.
  compose =
    base: children:
    if children == [ ] then
      base
    else
      pkgs.runCommand "ws-composed-${base.name or "tree"}" { } ''
        set -euo pipefail
        mkdir -p "$out"
        cp -a ${base}/. "$out/"
        chmod -R u+w "$out"
        ${lib.concatStrings (
          map (c: ''
            mkdir -p "$out/$(dirname "${c.path}")"
            if [ -d "${c.source}" ]; then
              mkdir -p "$out/${c.path}"
              cp -a "${c.source}"/. "$out/${c.path}"/
            else
              cp -a "${c.source}" "$out/${c.path}"
            fi
          '') children
        )}
      '';

  # nunchux: the pinned checkout with the .platform marker composed in
  # (with it present, upstream's ensure_binary never fetches
  # releases/latest unchecksummed)
  nunchuxTree =
    compose
      (pkgs.fetchFromGitHub {
        inherit (nunchuxPin)
          owner
          repo
          rev
          hash
          ;
      })
      [
        {
          path = "bin/.platform";
          source = ./nunchux/files/.tmux/plugins/nunchux/bin/.platform;
        }
      ];

  # the pin manifest: the declared pins, deployed beside the checkouts —
  # the verify lane's only anchor (verified against the DEPLOYED pin,
  # never a repo file). url+rev rows (the verify lane's shape), derived
  # from the owner/repo literals above so the manifest can never disagree
  # with the fetch.
  pinsManifest = builtins.toJSON {
    plugins = builtins.mapAttrs (_: pin: {
      url = "https://github.com/${pin.owner}/${pin.repo}";
      inherit (pin) rev;
    }) pluginPins;
    nunchux = {
      url = "https://github.com/${nunchuxPin.owner}/${nunchuxPin.repo}";
      inherit (nunchuxPin) rev version repo_linux_amd64_sha256;
    };
  };

  # the theme-slot launcher config, rendered natively: the template's slot
  # references substitute from the extracted tokens (byte-equal to
  # upstream's default config — only the two slot references carry the
  # theme rebrand)
  nunchuxConfig = theme.assertNoUnresolved (
    theme.renderSlots (builtins.readFile ./nunchux/files/.config/nunchux/config)
  );
in
{
  config = {
    home.file = lib.mkMerge (
      [
        # the managed config: the payload file, and the XDG link to it
        # (intra-home — the walker's mkOutOfStoreSymlink shape, declared)
        {
          ".tmux.conf".source = ./tmux/files/.tmux.conf;
          ".config/tmux/tmux.conf".source =
            config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/.tmux.conf";
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
