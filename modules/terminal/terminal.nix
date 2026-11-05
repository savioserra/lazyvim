# The terminal domain: eza and starship with their rc fragments.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.workstation.terminal.enable = lib.mkEnableOption "eza, starship, tmux and nunchux" // {
    default = true;
  };

  config = lib.mkIf config.workstation.terminal.enable {
    home.packages = [
      pkgs.eza
      pkgs.starship
    ];

    workstation.shell.fragments = [
      {
        target = ".bashrc";
        id = "managed-eza";
        order = 40;
        domain = "terminal";
        marker = "# workstation: managed eza ls";
        payload = ./fragments/managed-eza.sh;
      }
      {
        target = ".zshrc";
        id = "managed-eza-zsh";
        order = 40;
        domain = "terminal";
        marker = "# workstation: managed eza ls";
        payload = ./fragments/managed-eza.sh;
      }
      {
        target = ".bashrc";
        id = "managed-starship";
        order = 50;
        domain = "terminal";
        marker = "# workstation: managed starship prompt";
        payload = ./fragments/managed-starship.sh;
      }
      {
        target = ".zshrc";
        id = "managed-starship-zsh";
        order = 60;
        domain = "terminal";
        marker = "# workstation: managed starship prompt";
        payload = ./fragments/managed-starship-zsh.sh;
      }
    ];
  };
}
