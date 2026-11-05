# The foundation domain (always on): the rc lane fragments, fd, ripgrep,
# lazygit, mise, newt, direnv + nix-direnv, the starship config.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  tools = {
    inherit (pkgs) fd ripgrep lazygit;
  };

  frag = id: order: marker: {
    inherit id order marker;
    domain = "foundation";
    payload = ./fragments + "/${id}.sh";
  };

  fragments = [
    (frag "user-local-bin" 10 "# workstation: managed user-local bin")
    (frag "managed-profile" 20 "# workstation: load managed profile")
    (frag "managed-editor-env" 70 "# workstation: managed editor env")
    (frag "managed-direnv" 80 "# workstation: managed direnv hook")
    (frag "managed-direnv-zsh" 90 "# workstation: managed direnv hook")
  ];

  fragmentTargets = {
    user-local-bin = [
      ".profile"
      ".bashrc"
      ".zshrc"
    ];
    managed-profile = [ ".bash_profile" ];
    managed-editor-env = [
      ".profile"
      ".bashrc"
      ".zshrc"
    ];
    managed-direnv = [ ".bashrc" ];
    managed-direnv-zsh = [ ".zshrc" ];
  };

  fragmentEntries = lib.concatMap (
    f:
    map (target: {
      inherit target;
      id = f.id;
      order = f.order;
      domain = f.domain;
      marker = f.marker;
      payload = f.payload;
    }) fragmentTargets.${f.id}
  ) fragments;

  starshipToml = ./starship.toml;

  operatorExtras = builtins.toFile "workstation-operator-extras" config.workstation.foundation.shell.extras;

in
{
  options.workstation.foundation = {
    shell.extras = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "The operator's interactive shell lines, rendered last in .bashrc and .zshrc.";
    };
  };

  config = {
    workstation.shell.fragments =
      fragmentEntries
      ++ lib.optionals (config.workstation.foundation.shell.extras != "") [
        {
          target = ".bashrc";
          id = "operator-extras";
          order = 100;
          domain = "foundation";
          trailing = true;
          marker = "# workstation: operator extras";
          payload = operatorExtras;
        }
        {
          target = ".zshrc";
          id = "operator-extras";
          order = 100;
          domain = "foundation";
          trailing = true;
          marker = "# workstation: operator extras";
          payload = operatorExtras;
        }
      ];

    home.file = {
      ".config/starship.toml".source = starshipToml;
    };

    home.packages = [
      tools.fd
      tools.ripgrep
      tools.lazygit
      pkgs.mise
      pkgs.newt
    ];

    programs.direnv = {
      enable = true;
      nix-direnv.enable = true;
      enableBashIntegration = false;
      enableZshIntegration = false;
    };
  };
}
