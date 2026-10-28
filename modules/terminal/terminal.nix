# The terminal domain's shell surface: eza is the managed ls (icons,
# directories first), deployed beside the domain's tmux/nunchux
# capabilities. The order slots are the rc lane's global round tens (40
# the aliases, 50/60 the per-shell prompt init — the numbers are the
# shared scale, nix/lib/shell-lane.nix).
{
  config,
  lib,
  pkgs,
  ...
}:
{
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
