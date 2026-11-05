# The nunchux member (linux): the pinned checkout with its .platform marker
# and the theme-rendered launcher config.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  theme = config.workstation.theme.lib;

  nunchuxPin = {
    owner = "datamadsen";
    repo = "nunchux";
    rev = "1546eaa980d834c331496ea9d51942be07ea9fdd";
    hash = "sha256-C7sXigf8qB5umoZSU8nsqj6vPdd8NMhmTg8B64rysUw=";
    version = "3.1.3";
    repo_linux_amd64_sha256 = "8a6e46d937ee76ac6a483865c800de9208aabbe1dbc620473eb5e6b7d86b7b14";
  };

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

  nunchuxConfig = theme.assertNoUnresolved (
    theme.renderSlots (builtins.readFile ./files/.config/nunchux/config)
  );
in
{
  options.workstation.terminal.nunchux.enable = lib.mkEnableOption "the nunchux launcher (linux)" // {
    default = pkgs.stdenv.hostPlatform.isLinux;
    defaultText = lib.literalExpression "pkgs.stdenv.hostPlatform.isLinux";
  };

  config =
    lib.mkIf (config.workstation.terminal.enable && config.workstation.terminal.nunchux.enable)
      {
        assertions = [
          {
            assertion = pkgs.stdenv.hostPlatform.isLinux;
            message = "workstation.terminal.nunchux is linux-only";
          }
        ];

        workstation.terminal.pins.nunchux = {
          url = "https://github.com/${nunchuxPin.owner}/${nunchuxPin.repo}";
          inherit (nunchuxPin)
            rev
            version
            repo_linux_amd64_sha256
            ;
        };

        home.packages = [ pkgs.fzf ];

        home.file = {
          ".tmux/plugins/nunchux".source = nunchuxTree;
          ".config/nunchux/config".text = nunchuxConfig;
        };
      };
}
