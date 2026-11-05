# The theme domain: the library option and the token file
# (~/.local/state/workstation/theme.json).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  theme = config.workstation.theme.lib;

  themeTokens = pkgs.writeText "workstation-theme-tokens.json" (
    builtins.toJSON {
      palette = theme.palette;
      slots = theme.slots;
    }
  );
in
{
  options.workstation.theme = {
    enable = lib.mkEnableOption "the deployed theme token file" // {
      default = true;
    };
    lib = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      default = import ./theme.nix { inherit lib; };
      defaultText = lib.literalExpression "import ./theme.nix { inherit lib; }";
      description = "The theme library: palette, slots, renderSlots, assertNoUnresolved.";
    };
  };

  config = lib.mkIf config.workstation.theme.enable {
    home.file.".local/state/workstation/theme.json".source = themeTokens;
  };
}
