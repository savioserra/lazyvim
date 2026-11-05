# The agent domain: hermes (runtime pin, launcher, skills, extensions)
# and herdr. Hot-home owners: the pinned checkout
# (~/.hermes/hermes-agent - clone/fetch only when absent or clean-and-
# behind; dirty or runtime-advanced trees are never touched; a failed git
# step defers with a named receipt). The deployed pin manifest
# (.local/opt/hermes/pin.json) is the verify lane's only anchor.
#
# skills: one entry symlink per skill per target profile; the skills
# PARENT stays hot (hermes seeds its bundled skills there) - a declared
# name shadows a bundled one (asserted at eval). extensions: gateway
# plugin trees as derivations, entry-linked into ~/.hermes/plugins.
# Skill payloads are never copied into hot home.
#
# The interpreter is pkgs.python314, floored at the release the pinned
# rev's pm/lock.json carries (loud eval on mismatch). herdr has no
# nixpkgs coverage: one download pin, inline below.
#
# a2a: the A2A node (programs.hermes.a2a) — the inbound platform, the
# a2a toolset, the tailnet bind and the declared peers, converged into
# config.yaml/.env by an activation through the hermes CLI
# (files/a2a-converge.sh); peers come from the machine's discovery file
# (hosts/peers.nix, written by `workstation peers`).
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  hermes = config.programs.hermes;

  # the runtime pin: the agent domain's own declared data (owner/repo/rev
  # + the hermetic hash - one pin, one owner, one surface). The tree feeds
  # the interpreter floor's lock read; it never enters the closure.
  hermesRev = "b23600860f82bd66d345c0a1baefd0f264605955";
  hermesTree = pkgs.fetchFromGitHub {
    owner = "NousResearch";
    repo = "hermes-agent";
    rev = hermesRev;
    hash = "sha256-RSsNOW1WqtaxORPVkUyXnUzIjOEjx7Vzvx49HQsue8A=";
  };
  hermesPin = {
    url = "https://github.com/NousResearch/hermes-agent";
    rev = hermesRev;
    tree = hermesTree;
  };

  # the interpreter's version floor: the release the pinned hermes rev's
  # pm/lock.json names (packages.python.version — "3.14.7+<buildtag>"; the
  # semver prefix is the floor). Read from the pinned tree so a hermes rev
  # bump re-derives the floor at eval — the eval dies naming both versions
  # when the nixpkgs lock lags.
  lockedPythonVersion =
    if hermes.pin == null then
      null
    else
      let
        lock = builtins.fromJSON (builtins.readFile (hermes.pin.tree + "/pm/lock.json"));
        locked =
          lock.packages.python.version
            or (throw "workstation-agent: the pinned hermes rev's pm/lock.json carries no packages.python entry — the interpreter floor cannot be derived");
      in
      builtins.head (lib.splitString "+" locked);

  hermesPython =
    assert
      lockedPythonVersion == null
      || lib.versionAtLeast pkgs.python314.version lockedPythonVersion
      || throw "workstation-agent: pkgs.python314 ${pkgs.python314.version} predates the release the pinned hermes rev's pm/lock.json carries (${lockedPythonVersion}) — update the nixpkgs lock, or the hermes-agent rev must move to a lock the nixpkgs set satisfies";
    pkgs.python314;

  # herdr keeps a download pin: no nixpkgs coverage (upstream ships
  # release binaries only — no package in either pinned nixpkgs set), so
  # it stays the substrate's ONE download pin, inline in its owning
  # module (one pin, one owner, one surface — a bump moves these rows and
  # the consumer together). Archive-less: the fetched bytes ARE the
  # binary.
  herdrVersion = "0.9.0";
  herdrPin =
    if pkgs.stdenv.hostPlatform.isx86_64 && pkgs.stdenv.hostPlatform.isLinux then
      {
        url = "https://github.com/herdrdev/herdr/releases/download/v${herdrVersion}/herdr-linux-x86_64";
        sha256 = "4fa1a01158dd8043da92d31b270780b0dcc10603038d9b61cac4d81ab63fb71f";
      }
    else if pkgs.stdenv.hostPlatform.isAarch64 && pkgs.stdenv.hostPlatform.isDarwin then
      {
        url = "https://github.com/herdrdev/herdr/releases/download/v${herdrVersion}/herdr-macos-aarch64";
        sha256 = "32b53df09872628059c789a69f02a6b8e29e14ddf26711421f3463f70c1aef17";
      }
    else
      throw "workstation-agent: no herdr release asset declared for system '${pkgs.system}' (the pin knows linux x86_64 and darwin arm64)";
  herdr =
    pkgs.runCommand "herdr-${herdrVersion}"
      {
        src = pkgs.fetchurl herdrPin;
        passthru.pinVersion = herdrVersion;
      }
      ''
        install -Dm755 "$src" "$out/bin/herdr"
      '';

  launcher =
    pkgs.runCommand "ws-hermes-launcher" { }
      # the payload lands 0644 in git; the launcher is a PATH entry, so the
      # store copy carries the executable bit (the old envelope's
      # `executable: true`, native)
      ''
        install -Dm755 ${./files/hermes-launcher.sh} "$out/hermes-launcher"
      '';

  # the deployed pin manifest: the verify lane's only anchor (the checkout
  # HEAD and the interpreter are verified against the DEPLOYED pin, never a
  # repo file). Null-safe on the pin: a null pin deploys an empty engine
  # row and the module's assertion fires the friendly message — the eval
  # never dies on a type error first.
  pinJson = builtins.toJSON {
    engine = {
      url = if hermes.pin != null then hermes.pin.url else "";
      rev = if hermes.pin != null then hermes.pin.rev else "";
    };
    python = pkgs.python314.version;
  };

  # --- the A2A node --------------------------------------------------------
  a2a = hermes.a2a;
  helpers = import ./packages.nix { inherit pkgs; };
  # the fleet member service runs where the node serves on the tailnet
  fleetOn = a2a.enable && a2a.tailnet && a2a.fleet.enable;
  fleetEnv = {
    WORKSTATION_FLEET_PORT = toString a2a.fleet.port;
    WORKSTATION_A2A_PORT = toString a2a.port;
    WORKSTATION_HERMES = "${hermes.package}/hermes-launcher";
  };
  # the outbound token's env name per peer: the config entry carries the
  # ${...} reference, the operator's .env carries the value
  tokenEnv = alias: "A2A_PEER_TOKEN_" + lib.toUpper (lib.replaceStrings [ "-" ] [ "_" ] alias);
  dnsLabel = "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?";
  # the declared state the converge reads (a store file: no secret values)
  a2aDesired = pkgs.writeText "hermes-a2a.json" (
    builtins.toJSON {
      inherit (a2a) enable port tailnet;
      name = if a2a.name == null then "" else a2a.name;
      platforms = a2a.toolsetPlatforms;
      peers = lib.mapAttrs (alias: peer: {
        inherit (peer) url timeout capabilities;
        auth = {
          type = "bearer";
          token = "\${${tokenEnv alias}}";
        };
      }) a2a.peers;
      tokenEnvs = lib.mapAttrs (alias: _: tokenEnv alias) a2a.peers;
    }
  );

  # the agent's authored skills: the option setters' source - each tree
  # serves as ONE entry symlink per target profile (the rendering lane
  # lives in nix/modules/workstation-options.nix, so the report fold
  # attributes every entry to the capability that set it)
  authoredSkills = import ./skills.nix { inherit self; };
in
{
  options.programs.hermes = {
    # the runtime pin: the flake input's fetchGit rev, surfaced per
    # capability. Unset means the agent domain serves no runtime: an eval
    # that reads hermes surfaces without a pin fails loudly with the name
    # of the missing flake output.
    pin = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            url = lib.mkOption {
              type = lib.types.str;
              description = "The hermes-agent upstream git URL (the clone surface).";
            };
            rev = lib.mkOption {
              type = lib.types.str;
              description = "The pinned hermes-agent commit.";
            };
            tree = lib.mkOption {
              type = lib.types.raw;
              description = ''
                The pinned tree as the caller's flake input value — build-time
                assertions read it; it never enters the deployed closure.
              '';
            };
          };
        }
      );
      default = hermesPin;
      defaultText = lib.literalExpression "hermesPin";
      description = ''
        The hermes-agent runtime pin (upstream URL, pinned rev, pinned
        tree), declared by this module.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = launcher;
      defaultText = lib.literalExpression "launcher";
      description = ''
        The engine launcher derivation: resolves the pinned interpreter and
        the pinned checkout from $HOME at run time, fails closed when
        either is missing. Deployed at .local/opt/hermes/bin/hermes and on
        PATH as .local/bin/hermes.
      '';
    };

    a2a = {
      enable =
        lib.mkEnableOption "the A2A node: the inbound platform, the a2a toolset, the tailnet bind and the declared peers"
        // {
          default = true;
        };

      port = lib.mkOption {
        type = lib.types.port;
        default = 9900;
        description = ''
          The inbound A2A port (platforms.a2a.extra.port): the port this
          node serves, the port `workstation peers` probes.
        '';
      };

      name = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching "[A-Za-z0-9.-]+");
        default = null;
        description = ''
          This node's MagicDNS name: the Agent Card name (A2A_AGENT_NAME)
          and the advertised URL http://<name>:<port> (A2A_PUBLIC_URL, set
          with the tailnet bind). The legs set the captured identity's
          host; null leaves hermes' hostname-derived default.
        '';
      };

      tailnet =
        lib.mkEnableOption "the tailnet bind: A2A_HOST is this node's tailnet IPv4 (hermes widens past loopback only once an inbound token exists)"
        // {
          default = true;
        };

      toolsetPlatforms = lib.mkOption {
        type = lib.types.listOf (lib.types.strMatching "[a-z0-9_]+");
        default = [ "cli" ];
        description = "The hermes platforms whose sessions get the a2a client toolset.";
      };

      fleet = {
        enable =
          lib.mkEnableOption "the fleet member service: tailnet nodes of this tailscale user pair with this node automatically (workstation-fleet serve)"
          // {
            default = true;
          };
        port = lib.mkOption {
          type = lib.types.port;
          default = 9902;
          description = ''
            The fleet port on the tailnet IPv4: `GET /fleet` marks a member,
            `POST /join` pairs the caller (identified by `tailscale whois`,
            accepted only for this node's tailscale user).
          '';
        };
      };

      peers = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              url = lib.mkOption {
                type = lib.types.strMatching "https?://[A-Za-z0-9.-]+(:[0-9]+)?/?";
                description = "The peer's A2A endpoint: http://<node>:<port> (its MagicDNS name).";
              };
              timeout = lib.mkOption {
                type = lib.types.ints.between 1 3600;
                default = 120;
                description = "Seconds a call to this peer may take.";
              };
              capabilities = lib.mkOption {
                type = lib.types.listOf (lib.types.strMatching "[A-Za-z0-9._-]+");
                default = [ ];
                description = "The capabilities a2a_orchestrate routes to this peer.";
              };
            };
          }
        );
        default = { };
        description = ''
          The peers this node calls, keyed by MagicDNS name — the name is
          also the peer's inbound identity (a2a.trusted_peers, the name in
          its A2A_PEER_TOKENS row). Each renders an a2a_agents entry whose
          bearer token is the env reference A2A_PEER_TOKEN_<NAME>. The
          legs import hosts/peers.nix.
        '';
      };
    };
  };

  # the selection gate (workstation.agent.enable, nix/lib/selections.nix)
  # wraps this CONFIG block: the option DECLARATIONS above
  # (programs.hermes.pin/package) stay ungated so every composition that
  # loads the domain modules still carries them; disabled = the definitions
  # skip, never the files
  config = lib.mkIf config.workstation.agent.enable {
    # --- the eval-time contract --------------------------------------------
    assertions = [
      {
        assertion = hermes.pin != null;
        message =
          "programs.hermes.pin is unset — the flake must surface "
          + "`hermesAgentPin` (its pinned hermes-agent input: url, rev, "
          + "tree); see outputs.hermesAgentPin in flake.nix";
      }
    ]
    ++ map (name: {
      assertion = hermes.pin.tree == null || !builtins.pathExists (hermes.pin.tree + "/skills/${name}");
      message =
        "programs.hermes.skills.${name} collides with a skill the pinned "
        + "hermes-agent bundles — skills_sync owns that name at runtime "
        + "and would fight the declared entry symlink; rename the "
        + "declared skill";
    }) (builtins.attrNames (lib.filterAttrs (_: skill: skill.enable) hermes.skills))
    ++ map (alias: {
      assertion = builtins.match dnsLabel alias != null;
      message =
        "programs.hermes.a2a.peers.${alias}: a peer is keyed by its MagicDNS name "
        + "(a DNS label: lowercase letters, digits, '-')";
    }) (builtins.attrNames a2a.peers);

    # --- the agent's authored skills + the runtime stack --------------------
    # (the skill ENTRY rendering lives in nix/modules/workstation-options.nix
    # — the cross-capability lane — so the report fold attributes every
    # entry to the capability that set it)
    programs.hermes.skills = lib.mapAttrs (_: source: {
      enable = true;
      inherit source;
    }) authoredSkills;

    home.file = {
      # the pinned interpreter tree the launcher resolves at run time
      # (pkgs.python314, floored at the locked release — see above)
      ".local/opt/hermes/python".source = hermesPython;
      # the pin manifest: the verify lane's anchor (the deployed pin,
      # never a repo file)
      ".local/opt/hermes/pin.json".text = pinJson;
      # the engine launcher: the payload file at its runtime home...
      ".local/opt/hermes/bin/hermes".source = "${hermes.package}/hermes-launcher";
      # ...and the PATH entry — the store path links directly, no
      # ../opt indirection
      ".local/bin/hermes".source = "${hermes.package}/hermes-launcher";
      # herdr: the one download pin, the same direct store-path link
      ".local/bin/herdr".source = "${herdr}/bin/herdr";
    };

    # --- the pinned checkout (hot home; activation-managed) ----------------
    home.activation.ensure-hermes-checkout = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      url=${lib.escapeShellArg (if hermes.pin != null then hermes.pin.url else "")}
      rev=${lib.escapeShellArg (if hermes.pin != null then hermes.pin.rev else "")}
      checkout="$HOME/.hermes/hermes-agent"
      if [ -z "$rev" ]; then
        echo "workstation: hermes checkout ensure deferred — programs.hermes.pin is unset (the module's assertion names the fix)"
      elif ! command -v git >/dev/null 2>&1; then
        echo "workstation: hermes checkout ensure deferred — git unavailable on PATH"
      elif [ ! -d "$checkout/.git" ]; then
        if git clone --quiet "$url" "$checkout" && git -C "$checkout" checkout --quiet --detach "$rev"; then
          echo "workstation: hermes checkout cloned at the pinned commit $rev"
        else
          echo "workstation: hermes checkout ensure deferred — clone failed (offline or unreachable)"
        fi
      else
        head=$(git -C "$checkout" rev-parse HEAD 2>/dev/null || true)
        dirty=$(git -C "$checkout" status --porcelain 2>/dev/null | head -n 1)
        if [ -n "$dirty" ]; then
          echo "workstation: hermes checkout dirty — runtime state untouched"
        elif [ "$head" = "$rev" ]; then
          echo "workstation: hermes checkout already at the pinned commit"
        elif git -C "$checkout" merge-base --is-ancestor "$head" "$rev" 2>/dev/null; then
          if git -C "$checkout" fetch --quiet origin "$rev" && git -C "$checkout" checkout --quiet --detach "$rev"; then
            echo "workstation: hermes checkout fetched to the pinned commit $rev"
          else
            echo "workstation: hermes checkout ensure deferred — fetch failed (offline or unreachable)"
          fi
        else
          echo "workstation: hermes checkout runtime-advanced ($head) — untouched"
        fi
      fi
    '';

    # --- the A2A node (hot home; activation-managed) ------------------------
    # config.yaml and .env are the runtime's: the converge writes only the
    # declared keys, through the hermes CLI, and retracts the ones the
    # declaration drops (a disabled node retracts everything it set). A
    # failed step defers with a named receipt — the switch never fails on it.
    home.activation.converge-hermes-a2a =
      lib.hm.dag.entryAfter [ "linkGeneration" "ensure-hermes-checkout" ]
        ''
          if HERMES_HOME="$HOME/.hermes" WORKSTATION_STATE="$HOME/.local/state/workstation" \
            ${helpers.workstation-a2a-converge}/bin/workstation-a2a-converge \
            ${a2aDesired} "${hermes.package}/hermes-launcher"; then
            :
          else
            echo "workstation: a2a converge deferred — the receipts above name the step; the next apply retries"
          fi
        '';

    # --- the fleet member service --------------------------------------------
    # the same program on both platforms: a systemd user unit (linux) or a
    # launchd agent (darwin), restarted on failure, bound to the tailnet
    # IPv4 once the tailnet is up. The linux unit is a plain config file
    # plus its own activation: home-manager's systemd module skips root.
    xdg.configFile."systemd/user/workstation-fleet.service" =
      lib.mkIf (fleetOn && pkgs.stdenv.hostPlatform.isLinux)
        {
          text = ''
            [Unit]
            Description=workstation fleet member (A2A tailnet pairing)

            [Service]
            ExecStart=${helpers.workstation-fleet}/bin/workstation-fleet serve
            ${
              lib.concatStrings (lib.mapAttrsToList (name: value: "Environment=${name}=${value}\n") fleetEnv)
            }Restart=always
            RestartSec=10

            [Install]
            WantedBy=default.target
          '';
        };
    home.activation.workstation-fleet = lib.mkIf pkgs.stdenv.hostPlatform.isLinux (
      lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        # systemctl/loginctl are the host's: outside the activation PATH
        PATH=$PATH:/usr/bin:/bin
        ws_unit=${config.xdg.configHome}/systemd/user/workstation-fleet.service
        ws_stamp=${config.home.homeDirectory}/.local/state/workstation/fleet.unit
        if [ -e "$ws_unit" ]; then
          if systemctl --user show-environment >/dev/null 2>&1; then
            ws_want=$(readlink -f "$ws_unit")
            systemctl --user daemon-reload
            systemctl --user enable workstation-fleet.service >/dev/null 2>&1 || true
            if [ "$(cat "$ws_stamp" 2>/dev/null)" != "$ws_want" ] ||
              ! systemctl --user is-active -q workstation-fleet.service; then
              if systemctl --user restart workstation-fleet.service; then
                mkdir -p "''${ws_stamp%/*}" && printf '%s\n' "$ws_want" >"$ws_stamp"
                echo "workstation: fleet member service running (port ${toString a2a.fleet.port})"
              else
                echo "workstation: fleet member service failed to start — journalctl --user -u workstation-fleet"
              fi
            fi
            # a user service outlives the login session only with linger
            if [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" = no ]; then
              loginctl enable-linger "$(id -un)" 2>/dev/null ||
                echo "workstation: the fleet stops at logout — run: sudo loginctl enable-linger $(id -un)"
            fi
          else
            echo "workstation: fleet member service deferred — no user systemd session; run: systemctl --user enable --now workstation-fleet"
          fi
        elif [ -f "$ws_stamp" ]; then
          systemctl --user stop workstation-fleet.service 2>/dev/null || true
          rm -f "${config.xdg.configHome}/systemd/user/default.target.wants/workstation-fleet.service" "$ws_stamp"
          systemctl --user daemon-reload 2>/dev/null || true
          echo "workstation: fleet member service stopped (the fleet is off)"
        fi
      ''
    );
    launchd.agents.workstation-fleet = lib.mkIf (fleetOn && pkgs.stdenv.hostPlatform.isDarwin) {
      enable = true;
      config = {
        ProgramArguments = [
          "${helpers.workstation-fleet}/bin/workstation-fleet"
          "serve"
        ];
        EnvironmentVariables = fleetEnv;
        KeepAlive = true;
        RunAtLoad = true;
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/workstation-fleet.log";
      };
    };

    # --- the domain's tombstone --------------------------------------------
    workstation.retire = [ ".hermes/skills/lazyvim/SKILL.md" ];
  };
}
