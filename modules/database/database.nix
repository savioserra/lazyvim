# The database domain: the terminal SQL IDE (harlequin) and its headless
# agent CLI (hsql - same upstream distribution). The hsql agent skill is
# generated from the installed derivation by the tool's own --skill
# generator (version-matched, offline, from the store).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # the agent skill: generated from the installed derivation - the tool
  # ships one and serves it version-matched. The generator decides
  # file-vs-dir by the target's existence, so the build stages into a
  # pre-created dir and copies out - one shape, always.
  hsqlSkill =
    pkgs.runCommand "hsql-agent-skill-${pkgs.harlequin.version}"
      {
        nativeBuildInputs = [ pkgs.harlequin ];
        passthru.version = pkgs.harlequin.version;
      }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME" "$TMPDIR/skill"
        hsql --skill -o "$TMPDIR/skill"
        mkdir -p "$out"
        cp -a "$TMPDIR/skill/." "$out/"
      '';
in
{
  options.workstation.database.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Whether the database capability (harlequin + hsql) deploys.";
  };

  config = lib.mkIf config.workstation.database.enable {
    home.packages = [ pkgs.harlequin ];

    programs.hermes.skills.hsql = {
      enable = true;
      source = hsqlSkill;
    };
  };
}
