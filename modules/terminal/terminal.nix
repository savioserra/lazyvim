# The terminal domain's shell surface: eza is the managed ls (icons,
# directories first), deployed beside the domain's tmux/nunchux
# capabilities. The order slot is the terminal domain's own lane.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  config = lib.mkIf config.workstation.terminal.enable {
    home.packages = [ pkgs.eza ];

    workstation.shell.fragments = [
      {
        target = ".bashrc";
        id = "managed-eza";
        order = 10;
        domain = "terminal";
        marker = "# workstation: managed eza ls";
        payload = ./fragments/managed-eza.sh;
      }
      {
        target = ".zshrc";
        id = "managed-eza-zsh";
        order = 10;
        domain = "terminal";
        marker = "# workstation: managed eza ls";
        payload = ./fragments/managed-eza.sh;
      }
      {
        target = ".bashrc";
        id = "managed-starship";
        order = 20;
        domain = "terminal";
        marker = "# workstation: managed starship prompt";
        payload = ./fragments/managed-starship.sh;
      }
      {
        target = ".zshrc";
        id = "managed-starship-zsh";
        order = 20;
        domain = "terminal";
        marker = "# workstation: managed starship prompt";
        payload = ./fragments/managed-starship-zsh.sh;
      }
    ];
  };
}
