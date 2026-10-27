# The Node language capability: the pinned nvm tree with the pinned node
# nested inside it (the claim composition — one store tree, declared
# parent-first), the .node-version declaration (the version pin's own
# source), the nvm.sh loader payload, and the managed-nvm rc fragments.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  pins = import ../../../nix/lib/pins.nix { inherit lib pkgs; };

  # the node version pin is the payload's .node-version file (the
  # change-rule's canonical address), read — never duplicated
  nodeVersion = lib.trim
    (builtins.readFile ./files/.node-version);

  nvmTree = pins.tool "nvm_sh" {
    version = "0.40.4";
    # one upstream archive serves both platform legs (same bytes, same sha)
    url = "https://github.com/nvm-sh/nvm/archive/refs/tags/v{V}.tar.gz";
    sha256 = "5949b50e4640f2be2263f963952673d7f1a8745a83f05365e99f032fe78307fd";
    archive = "tar.gz";
    probe = {
      member = "nvm.sh";
      sha256 = "7bb0324a92b1b7a3d612a00fd361f0daa78960cb4d404e7e42acf76eb53f6850";
    };
  };

  nodeTree = pins.tool "node" {
    version = nodeVersion;
    url = {
      linux_x86_64 = "https://nodejs.org/dist/v{V}/node-v{V}-linux-x64.tar.xz";
      darwin_arm64 = "https://nodejs.org/dist/v{V}/node-v{V}-darwin-arm64.tar.xz";
    };
    sha256 = {
      linux_x86_64 = "14b342e71204f811bde6153be8e04b62aef63c236fef92b55f9c83154b409647";
      darwin_arm64 = "3f1cf157479c1480352083105e13faf9d008ede98e7e157746b6df940d197b94";
    };
    archive = "tar.xz";
    probe = {
      argv = [ "bin/node" "--version" ];
      output = "v{V}";
    };
  };

  # the node install tree nested inside the nvm tree (nvm's own layout:
  # $NVM_DIR/versions/node/v<version>)
  provisionedTree = pins.compose nvmTree [
    {
      path = "versions/node/v${nodeVersion}";
      source = nodeTree;
    }
  ];
in
{
  config = {
    workstation.shell.fragments = [
      {
        target = ".profile";
        id = "managed-nvm";
        marker = "# workstation: load managed nvm";
        payload = ./fragments/managed-nvm.sh;
      }
      {
        target = ".bashrc";
        id = "managed-nvm";
        marker = "# workstation: load managed nvm";
        payload = ./fragments/managed-nvm.sh;
      }
      {
        target = ".zshrc";
        id = "managed-nvm";
        marker = "# workstation: load managed nvm";
        payload = ./fragments/managed-nvm.sh;
      }
    ];

    home.file = {
      ".node-version".source = ./files/.node-version;
      ".config/shell/nvm.sh".source = ./files/nvm.sh;
      ".local/opt/nvm".source = provisionedTree;
    };
  };
}
