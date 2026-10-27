# The Node language capability: the nixpkgs runtime (the overlay's
# scoped pkgs.workstation-node, nodejs_24 from the foundation input —
# operator ruling 2026-10-27: nix owns the runtime; the nvm lane retired
# with the pins machinery — nvm was the old world's version manager, and
# its default-alias bug class dies structurally with it). The
# .node-version declaration is DERIVED from the runtime (one source: the
# nixpkgs version), so per-project version tools (mise et al) read the
# version this generation actually ships.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  # the version-class pin: the 24 major rides the nixpkgs set (the
  # foundation domain's pin-override overlay keeps it current); the patch
  # drift is nixpkgs' to maintain, never a SHA to keep alive. The SCOPED
  # name (pkgs.workstation-node, not pkgs.nodejs_24): nixpkgs' own
  # nodejs_24 is a build toolchain its own packages consume, and
  # retargeting the name would rehash those builds off the binary cache —
  # the overlay's scoping rule (see overlays.default).
  nodejs = pkgs.workstation-node;

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

        # the nvm lane's tombstones: the provisioned tree (the store claim at
        # .local/opt/nvm) and the rc loader payload — hosts carrying them from
        # the pin world lose them at the next activation, each with a named
        # receipt (the generation diff also retires them; the tombstones make
        # the retirement hold even where the diff is bypassed). The tree
        # entry's recursive = true is the declared consent: the activation
        # removes exactly that path recursively (the vps cutover, 2026-10-27:
        # a bare string entry met the tree with plain rm and the tombstone
        # silently stayed).
        workstation.retire = [
          ".config/shell/nvm.sh"
          {
            path = ".local/opt/nvm";
            recursive = true;
          }
        ];
      };
}
