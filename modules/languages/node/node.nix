# The Node language capability: the runtime (nodejs_24), the
# .node-version derived from it, and the editor profile entry.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  nodejs = pkgs.nodejs_24;

  # the derived version declaration (the change-rule's canonical address —
  # a store text file, not a module literal, so it can never drift from
  # the runtime)
  nodeVersionFile = pkgs.writeText "node-version" "${nodejs.version}\n";
in
{
  # the selection gate (workstation.languages.node.enable AND the domain
  # enable — a member deploys under its domain, nix/lib/selections.nix):
  # disabled = the definitions skip, never the files
  config =
    lib.mkIf (config.workstation.languages.enable && config.workstation.languages.node.enable)
      {
        home.packages = [ nodejs ];

        home.file.".node-version".source = nodeVersionFile;

        # the nvm lane's tombstones, each removed with a named receipt:
        # the provisioned tree (.local/opt/nvm, recursive = true) and the rc
        # loader payload.
        workstation.retire = [
          ".config/shell/nvm.sh"
          {
            path = ".local/opt/nvm";
            recursive = true;
          }
        ];
      };
}
