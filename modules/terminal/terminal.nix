# The terminal domain: eza (ls) and the starship prompt.
{
  config,
  lib,
  ...
}:
{
  options.workstation.terminal.enable = lib.mkEnableOption "eza, starship, tmux and nunchux" // {
    default = true;
  };

  config = lib.mkIf config.workstation.terminal.enable {
    programs.eza = {
      enable = true;
      icons = "auto";
      extraOptions = [ "--group-directories-first" ];
    };
    programs.bash.shellAliases.ls = "eza -lh";
    programs.zsh.shellAliases.ls = "eza -lh";

    programs.starship.enable = true;
    xdg.configFile."starship.toml".source = ./starship.toml;
  };
}
