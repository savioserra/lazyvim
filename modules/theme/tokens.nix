# The theme capability's deployed token surface: the store token path.
#
# tokens.lua is the canonical byte source; theme.nix extracts it at eval
# time, and THIS module deploys the extracted tokens as ONE store file at a
# stable hot path — the token path consumers watch:
#
#   ~/.local/state/workstation/theme.json
#
# The path is a plain symlink into the store that the switch re-points at
# every generation (the switch-time push: one re-link per switch, nothing
# polls — a consumer reads the file at startup or watches the link). The
# switch re-points this file; it is the
# theme's live surface now. Rollback restores the prior generation's link.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  # the theme library: the fail-closed tokens.lua extraction (the eval dies
  # loudly on a restructure it cannot read — never silently empty tokens)
  theme = import ./theme.nix {
    inherit lib;
    inherit self;
  };

  themeTokens = pkgs.writeText "workstation-theme-tokens.json" (
    builtins.toJSON {
      palette = theme.palette;
      slots = theme.slots;
    }
  );
in
{
  # the selection gate (workstation.theme.enable, nix/lib/selections.nix):
  # disabled = the definitions skip, never the files — the tokens.lua
  # extraction itself stays available to ungated consumers (the theme
  # library is data, not config)
  config = lib.mkIf config.workstation.theme.enable {
    home.file.".local/state/workstation/theme.json".source = themeTokens;
  };
}
