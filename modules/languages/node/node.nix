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
    (builtins.readFile
      (self + "/workstation/packages/languages/node/files/.node-version"));

  nvmTree = pins.tool "nvm_sh" {
    archive = "tar.gz";
    probe = {
      member = "nvm.sh";
      sha256 = "7bb0324a92b1b7a3d612a00fd361f0daa78960cb4d404e7e42acf76eb53f6850";
    };
  };

  nodeTree = pins.tool "node" {
    archive = "tar.xz";
    version = nodeVersion;
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
        marker = "# chezmoi: load managed nvm";
        payload = ./fragments/managed-nvm.sh;
      }
      {
        target = ".bashrc";
        id = "managed-nvm";
        marker = "# chezmoi: load managed nvm";
        payload = ./fragments/managed-nvm.sh;
      }
      {
        target = ".zshrc";
        id = "managed-nvm";
        marker = "# chezmoi: load managed nvm";
        payload = ./fragments/managed-nvm.sh;
      }
    ];

    home.file = {
      ".node-version".source =
        self + "/workstation/packages/languages/node/files/.node-version";
      ".config/shell/nvm.sh".source =
        self + "/workstation/packages/languages/node/files/nvm.sh";
      ".local/opt/nvm".source = provisionedTree;
    };
  };
}
