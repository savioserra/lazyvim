# The foundation domain (always on): bash and zsh, the user-local bin on
# PATH, fd, ripgrep, lazygit, mise, newt, direnv + nix-direnv.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  extras = config.workstation.foundation.shell.extras;
in
{
  options.workstation.foundation.shell.extras = lib.mkOption {
    type = lib.types.lines;
    default = "";
    description = "The operator's interactive shell lines, rendered last in .bashrc and .zshrc.";
  };

  config = lib.mkMerge [
    {
      programs.bash.enable = true;
      programs.zsh.enable = true;

      home.sessionPath = [
        "$HOME/.local/bin"
        "${config.home.profileDirectory}/bin"
      ];

      home.packages = [
        pkgs.fd
        pkgs.ripgrep
        pkgs.lazygit
        pkgs.mise
        pkgs.newt
      ];

      programs.direnv = {
        enable = true;
        nix-direnv.enable = true;
        enableBashIntegration = false;
      };
      programs.bash.initExtra = lib.mkOrder 1950 ''
        eval "$(${lib.getExe config.programs.direnv.package} hook bash)"
      '';
    }
    (lib.mkIf (extras != "") {
      programs.bash.initExtra = lib.mkOrder 2000 extras;
      programs.zsh.initContent = lib.mkOrder 2000 extras;
    })
  ];
}
