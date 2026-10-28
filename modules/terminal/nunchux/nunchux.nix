# The nunchux capability (terminal/nunchux): the pinned checkout
# (.tmux/plugins/nunchux), the .platform marker composed into it, and the
# theme-slot launcher config rendered natively from tokens.lua
# (workstationTheme.lib), asserted unresolved-slot-free. The checkout is a
# fetchFromGitHub pin; the `.platform` marker composes INTO the checkout
# (immutable store cannot host a file inside a dir symlink — the claim
# composition is a tiny local derivation), and with it present upstream's
# ensure_binary never fetches releases/latest unchecksummed. The pin row
# rides the terminal domain's declared manifest rows
# (workstation.terminal.pins) so the deployed manifest always matches the
# checkouts beside it. Nunchux is linux-only (its supported_hosts contract,
# carried as the platform gate — a darwin eval deploys nothing and the
# report's selections rows mark the path unavailable there).
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  theme = import ../../theme/theme.nix { inherit lib self; };

  # the checkout pin: the repo-tracked linux build's sha is the verify
  # lane's content pin; the release the rev carries rides the manifest row.
  # The release-asset checksum rows of the old inventory retired with it —
  # no build consumer (the `.platform` marker keeps upstream's
  # ensure_binary off the unchecksummed release fetches).
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

  # the pinned checkout with the .platform marker composed in
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
          source = ./files/.tmux/plugins/nunchux/bin/.platform;
        }
      ];

  # the theme-slot launcher config, rendered natively: the template's slot
  # references substitute from the extracted tokens (byte-equal to
  # upstream's default config — only the two slot references carry the
  # theme palette)
  nunchuxConfig = theme.assertNoUnresolved (
    theme.renderSlots (builtins.readFile ./files/.config/nunchux/config)
  );
in
{
  # the selection gate (workstation.terminal.nunchux.enable AND the domain
  # enable — a member deploys under its domain, nix/lib/selections.nix):
  # disabled = the definitions skip, never the files. The checkout and its
  # rendered config are platform-gated to linux INSIDE the file plane (the
  # supported_hosts contract — the original module's proven gate shape: the
  # platform read stays inside the declared option's value, never at the
  # config structure, where it would recurse through config.nixpkgs.pkgs);
  # the manifest row stays unconditional within the selection gate, exactly
  # the original domain's semantics — the manifest lists the terminal
  # domain's declared pins on every platform.
  config =
    lib.mkIf (config.workstation.terminal.enable && config.workstation.terminal.nunchux.enable)
      {
        # the manifest row rides the domain's declared rows (the tmux
        # capability renders the file)
        workstation.terminal.pins.nunchux = {
          url = "https://github.com/${nunchuxPin.owner}/${nunchuxPin.repo}";
          inherit (nunchuxPin)
            rev
            version
            repo_linux_amd64_sha256
            ;
        };

        # the launcher's runtime dependency: fzf (the popup menus are fzf
        # views; nunchux is its only consumer in the substrate)
        home.packages = lib.optionals pkgs.stdenv.isLinux [ pkgs.fzf ];

        home.file = lib.mkIf pkgs.stdenv.isLinux {
          ".tmux/plugins/nunchux".source = nunchuxTree;
          ".config/nunchux/config".text = nunchuxConfig;
        };
      };
}
