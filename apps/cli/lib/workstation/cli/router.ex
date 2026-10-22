defmodule Workstation.CLI.Router do
  @moduledoc """
  `workstation` command line — the fused front door of the engine.

  The engine is CLIENT/SERVER: the daemon is the only mutation engine and
  the only source of live state; the CLI is a thin protocol client
  (`Workstation.CLI.DaemonClient`). Every verb dispatch reduces to: ensure
  the daemon is up (spawn it detached from the same release when absent),
  send one op, render the result. Read verbs (`status`, `plan`, `diff`,
  `json <command>`) send `status.run` / `plan.run` / `diff.run`; lifecycle
  verbs send `bootstrap.run` / `sync.run` / `verify.run` / `pull.run` and
  the per-step `update.run`; `apply` confirms through `apply.run` via the
  plain runner or TUI screen. There is NO in-process fallback: a daemon
  that cannot be reached or spawned is a clear operator error. The one
  in-process path is `--input <file>` golden replay, which is offline by
  definition (`Workstation.CLI.Core` over a recorded envelope, no daemon
  involved).

  `apply` and `update` are interactive-first — the TUI is the DEFAULT for
  verbs with a screen, and there is no silent degradation: on a usable
  terminal they run the TUI screens; `--headless` forces the plain runner;
  a non-terminal stdout WITHOUT `--headless` is a hard error, never a
  plain fallback. The other lifecycle verbs are plain runs by nature (no
  screen exists).

  `workstation daemon` runs the resident daemon in the foreground;
  `workstation daemon stop` stops a running daemon (the manual stop path —
  nothing stops a daemon behind the operator's back).

  `-h/--help` is a global flag: every subcommand answers it with its usage
  and exit 0 BEFORE any dispatch — a help request never resolves a home,
  checks a terminal, stops a daemon, or runs the verb (the 2026-10-19
  aurora incident: `bootstrap --help` ran a real provisioning pass on a
  release that silently ignored the flag). Unknown flags are a usage error
  (exit 2) — never silently ignored on a mutating verb.

  `--home` selects the destination home (default: `$WORKSTATION_HOME`, else
  `$HOME` — the launcher shim rebases both to the same destination, so verbs
  address the intended home either way). The daemon serves exactly the home
  it booted with; ensure-daemon spawns it with the resolved `--home`, and a
  client that resolves a DIFFERENT home than a running daemon refuses to
  speak to it. `--engine-root` selects the engine checkout for the
  bootstrap/update steps (default: `$WORKSTATION_ENGINE_REPO`, else
  checkout-walk detection) and rides to the daemon through the spawn
  environment.

  Exit codes (docs/elixir.md carries the table): 0 ok; 1 no usable terminal
  for an interactive verb; 2 usage; 3 conflict-or-precondition (evaluation
  failure or apply-lock contention); 4 engine failure (native collection
  error, lifecycle step failure, daemon unavailable).
  """

  alias Workstation.CLI.Core
  alias Workstation.CLI.Capabilities
  alias Workstation.CLI.DaemonClient
  alias Workstation.CLI.Plain
  alias Workstation.CLI.Render
  alias Workstation.CLI.TUI
  alias Workstation.CLI.TUI.{Apply, Update}
  alias Workstation.CLI.Control
  alias Workstation.CLI.PreReplace
  alias Workstation.Core.CanonicalJSON
  alias Workstation.Daemon.Boot

  @no_terminal "workstation: no usable terminal; pass --headless for non-interactive runs"

  # Op budget for the read ops; lifecycle calls use the executors' longer
  # budget (lock queues and engine steps take minutes).
  @read_timeout_ms 120_000
  @lifecycle_timeout_ms 600_000

  def main(argv) do
    case Optimus.parse(parser(), argv) do
      {:ok, result} ->
        if help_requested?(result) do
          print_help([])
        else
          dispatch_from_result(result)
        end

      {:ok, [:json, command], result} ->
        if help_requested?(result) do
          print_help([:json, command])
        else
          dispatch(command, result, json: true)
        end

      {:ok, [:system, :applied], result} ->
        if help_requested?(result) do
          print_help([:system, :applied])
        else
          dispatch_system_applied(result)
        end

      {:ok, [command], result} ->
        if help_requested?(result) do
          print_help([command])
        else
          dispatch(command, result, json: false)
        end

      {:error, errors} ->
        fail(2, format_errors(errors))

      {:error, _subcommand_path, errors} ->
        fail(2, format_errors(errors))

      :version ->
        {:ok, IO.puts("workstation #{Application.spec(:cli, :vsn) || "0.0.0"}")}

      :help ->
        print_help([])

      {:help, subcommand_path} ->
        print_help(subcommand_path)
    end
  end

  ## parser

  # Public for the parse-shape regression (DaemonVerbTest pins the
  # ["daemon", "stop"] flattened positional through THIS spec, not a copy).
  def parser do
    Optimus.new!(
      name: "workstation",
      description: "workstation engine front end: read verbs report, lifecycle verbs mutate.",
      allow_unknown_args: false,
      parse_double_dash: true,
      # The global help flag: Optimus merges a `global` flag into EVERY
      # subcommand (hidden from their help), so `-h/--help` parses on any
      # invocation and the dispatch gate answers it before the verb runs —
      # without it, the flag landed in unknown-args (a usage error where it
      # was silently ignored on releases pre fail-closed: the aurora
      # `bootstrap --help` execution) or was swallowed by a positional
      # (the daemon ACTION).
      flags: [
        help: [
          short: "-h",
          long: "--help",
          help: "print the invoking command's usage and exit",
          global: true
        ]
      ],
      # Bare-verb (TUI shell) options: the boot dashboard layout pin.
      options: shell_options(),
      subcommands: [
        status: [
          name: "status",
          about: "engine status report",
          options: read_options()
        ],
        plan: [
          name: "plan",
          about: "engine plan report",
          options: read_options()
        ],
        diff: [
          name: "diff",
          about: "engine diff report",
          options: read_options()
        ],
        capabilities: [
          name: "capabilities",
          about:
            "capability-domain grouped listing (rollups by package attribution; drift-free informational output)",
          options: read_options() ++ scope_options(),
          flags: capability_flags()
        ],
        json: [
          name: "json",
          about: "emit the engine JSON wire report unchanged",
          subcommands: [
            status: [
              name: "status",
              about: "raw status JSON",
              options: read_options()
            ],
            plan: [
              name: "plan",
              about: "raw plan JSON",
              options: read_options()
            ],
            diff: [
              name: "diff",
              about: "raw diff JSON",
              options: read_options()
            ]
          ]
        ],
        bootstrap: [
          name: "bootstrap",
          about: "provision a home: managed tool pins, chezmoi backend, launcher",
          options: lifecycle_options()
        ],
        apply: [
          name: "apply",
          about: "apply the current desired state (TUI by default; --headless for plain)",
          options: lifecycle_options(),
          flags: [
            headless: [long: "--headless", help: "force the non-interactive plain runner"],
            adopt: [
              long: "--adopt",
              help:
                "operator-gated adoption: the refusal reports the full un-owned set with probe verdicts; " <>
                  "probe-verified targets are adopted (content-identity law: engine state wins the cutover)"
            ]
          ]
        ],
        update: [
          name: "update",
          about: "pull, bootstrap, apply, sync, verify — abort on first failure (TUI by default)",
          options:
            lifecycle_options() ++
              [
                resume_from: [
                  long: "--resume-from",
                  help:
                    "internal: resume the update chain at these comma-separated steps (set by the release handoff)",
                  value_name: "STEPS"
                ]
              ],
          flags: [headless: [long: "--headless", help: "force the non-interactive plain runner"]]
        ],
        sync: [
          name: "sync",
          about: "reconcile the journal's generation with the freshly collected desired state",
          options: lifecycle_options()
        ],
        verify: [
          name: "verify",
          about: "verify the launcher and every applied target fingerprint",
          options: lifecycle_options()
        ],
        pull: [
          name: "pull",
          about: "fast-forward the engine checkout (never resets a diverged tree)",
          options: lifecycle_options()
        ],
        system: [
          name: "system",
          about: "nix substrate surface: the generation-switch publish seam",
          subcommands: [
            applied: [
              name: "applied",
              about:
                "publish the applied nix generation on the daemon's system domain " <>
                  "(the workstation-switch drivers' receipt)",
              options: [
                generation: [
                  value_name: "N",
                  long: "--generation",
                  required: true,
                  parser: fn s -> parse_positive_integer(s) end,
                  help: "the applied nix profile generation (positive integer)"
                ],
                rollback_generation: [
                  value_name: "M",
                  long: "--rollback-generation",
                  parser: fn s -> parse_positive_integer(s) end,
                  help: "the generation the switch replaced (absent on a first-ever switch)"
                ]
              ]
            ]
          ]
        ],
        daemon: [
          name: "daemon",
          about: "run the resident daemon in the foreground (ensure-daemon spawns it detached)",
          args: [
            action: [
              value_name: "ACTION",
              # The BARE verb is the foreground boot (the ensure-daemon
              # spawn target); optimus args are required unless told so,
              # and an ACTION-required verb would strand the spawn on a
              # usage error. The only explicit action today is `stop`.
              required: false,
              help: "stop — stop a running daemon (the manual stop path)"
            ]
          ]
        ]
      ]
    )
  end

  # Boot options of the bare verb's TUI shell: `--preset N` pins the
  # dashboard's opening layout (0 full mosaic, 1 audit, 2 minimal; the
  # dispatch validates the number and fails with the shared stderr
  # contract). The TUI-only surface never touches the headless verbs.
  defp shell_options do
    [
      preset: [
        value_name: "N",
        long: "--preset",
        help: "boot dashboard layout: 0 full mosaic (default), 1 audit, 2 minimal"
      ]
    ]
  end

  defp read_options do
    [
      home: [
        value_name: "DIR",
        long: "--home",
        help: "destination home (default: $WORKSTATION_HOME, else $HOME)"
      ],
      input: [
        value_name: "FILE",
        long: "--input",
        help: "plan replay: recorded golden input.json instead of the live native catalog"
      ]
    ]
  end

  # Scope flags of the grouped `capabilities` listing: drill to one domain
  # (docs/capabilities.md naming: editor, terminal, theme, ...) or one
  # package inside its domain (nvim, tmux, ...).
  defp scope_options do
    [
      domain: [
        value_name: "DOMAIN",
        long: "--domain",
        help: "scope the listing to one capability domain (e.g. editor)"
      ],
      package: [
        value_name: "PACKAGE",
        long: "--package",
        help: "scope the listing to one package (implies file drill-down)"
      ]
    ]
  end

  defp capability_flags do
    [
      json: [
        long: "--json",
        help: "emit the grouped envelope as canonical JSON (workstation.capabilities.v1)"
      ],
      files: [
        long: "--files",
        help: "flatten to the old file-grained listing (deprecated spelling)"
      ]
    ]
  end

  defp lifecycle_options do
    [
      home: [
        value_name: "DIR",
        long: "--home",
        help: "destination home (default: $WORKSTATION_HOME, else $HOME)"
      ],
      engine_root: [
        value_name: "DIR",
        long: "--engine-root",
        help:
          "engine checkout for bootstrap/update (default: $WORKSTATION_ENGINE_REPO, else detection)"
      ]
    ]
  end

  ## help contract

  # The dispatch gate: `-h/--help` on ANY invocation prints the invoking
  # command's usage and exits 0. The gate runs before EVERY side effect —
  # home resolution, the terminal gate, the pre-replace daemon stop, the
  # foreground daemon boot — so a help request can never provision, apply,
  # update, or park a daemon.
  defp help_requested?(result), do: result.flags[:help] == true

  defp print_help([]), do: {:ok, IO.puts(Optimus.help(parser()))}

  defp print_help(subcommand_path) do
    lines = Optimus.Help.help(parser(), subcommand_path, help_columns())
    {:ok, IO.puts(Enum.join(lines, "\n"))}
  end

  # Optimus's own width probe (parse!/3 uses the same 80-column fallback);
  # piped/non-tty stdout renders at the fallback width.
  defp help_columns do
    case Optimus.Term.width() do
      {:ok, width} -> width
      _other -> 80
    end
  end

  ## dispatch

  # Bare `workstation`: on a usable terminal the verb IS the TUI home —
  # the application shell (owner directive 1); anywhere else the plain
  # verb help prints and the process exits 0. The non-TTY contract: the
  # bare verb NEVER hangs and NEVER starts a TUI blind.
  defp dispatch_from_result(result) do
    if usable_terminal?() do
      home = resolve_home(result)
      preset = parse_preset(result)
      TUI.Shell.DaemonEntry.run(destination: home, preset: preset)
    else
      {:ok, IO.puts(Optimus.help(parser()))}
    end
  end

  # The boot preset: default 0; a malformed value is a usage error (the
  # parser accepted any string — the 0..2 domain is the dispatch's job).
  defp parse_preset(result) do
    case result.options[:preset] do
      nil ->
        0

      value ->
        case Integer.parse(value) do
          {n, ""} when n in 0..2 ->
            n

          _other ->
            fail(2, "error: --preset must be 0, 1, or 2")
        end
    end
  end

  defp dispatch(command, result, mode) when command in [:status, :plan, :diff] do
    home = resolve_home(result)

    with {:ok, wire} <- evaluate(command, home, result),
         :ok <- emit(command, wire, mode) do
      :ok
    end
  end

  # The grouped capabilities verb: TWO read ops folded by
  # `Workstation.CLI.Capabilities` (taxonomy from the status wire, file
  # inventory from the plan wire). Informational output — planned changes
  # stay exit 0, matching the read verbs' drift-free contract.
  defp dispatch(:capabilities, result, _mode) do
    home = resolve_home(result)

    with {:ok, status} <- evaluate(:status, home, result),
         {:ok, plan} <- evaluate(:plan, home, result) do
      envelope =
        %{"status" => status, "plan" => plan}
        |> Capabilities.group()
        |> Capabilities.scope(domain: result.options[:domain], package: result.options[:package])

      if result.flags[:json] do
        {:ok, IO.puts(CanonicalJSON.encode(envelope))}
      else
        {:ok,
         IO.puts(
           Render.capabilities(
             envelope,
             domain: result.options[:domain],
             package: result.options[:package],
             files: result.flags[:files] == true
           )
         )}
      end
    end
  end

  # `bootstrap` (and every verb that may replace the installed release —
  # `apply`, `update` below) asks a LIVE daemon to exit gracefully BEFORE
  # any work is dispatched: the daemon runs the installed release in memory,
  # and a replacement under a surviving beam would leave stale code serving.
  # The refusal is fail-closed (never killed); the verb's own first call
  # re-spawns a fresh daemon on demand from the current release.
  defp dispatch(:bootstrap, result, _mode) do
    home = resolve_home(result)
    pre_replace_stop(home)

    case DaemonClient.call("bootstrap.run", %{}, client_opts(result, @lifecycle_timeout_ms)) do
      {:ok, record} ->
        emit_record(record)

      {:error, {tag, message}} when is_atom(tag) ->
        fail(4, "error: #{tag}: #{message}")

      # ensure-daemon's spawn refusal rides as a bare message (no release
      # binary, spawn failure) — engine exit, never a CaseClause crash.
      {:error, message} when is_binary(message) ->
        fail(4, "error: #{message}")

      # The daemon-side refusal classes arrive over the wire as STRING codes
      # (JSON) — the aurora bootstrap handoff crashed right here with a
      # CaseClauseError on a `locked` refusal whose holder pid was dead
      # (2026-10-14). Same mapping as the read verbs: the code keeps the
      # client exit table (`locked` is precondition, everything else engine).
      {:error, {code, message}} when is_binary(code) and is_binary(message) ->
        fail(lifecycle_exit(code), "error: #{code}: #{message}")

      {:error, code, message} ->
        fail(lifecycle_exit(code), "error: #{code}: #{message}")
    end
  end

  defp dispatch(command, result, _mode) when command in [:sync, :verify, :pull] do
    case DaemonClient.call(lifecycle_op(command), %{}, client_opts(result, @lifecycle_timeout_ms)) do
      {:ok, record} ->
        emit_record(record)

      {:error, {tag, message}} when is_atom(tag) ->
        fail(4, "error: #{tag}: #{message}")

      # ensure-daemon's spawn refusal rides as a bare message — engine exit,
      # never a CaseClause crash.
      {:error, message} when is_binary(message) ->
        fail(4, "error: #{message}")

      # Wire refusals are STRING-coded pairs (JSON) — same mapping as the
      # bootstrap arm above and the read verbs' client contract.
      {:error, {code, message}} when is_binary(code) and is_binary(message) ->
        fail(lifecycle_exit(code), "error: #{code}: #{message}")

      {:error, code, message} ->
        fail(lifecycle_exit(code), "error: #{code}: #{message}")
    end
  end

  # `workstation daemon` (no action) is the FOREGROUND boot: `Boot.run`
  # starts the tree and parks the caller, keeping this VM alive serving the
  # state socket — ensure-daemon spawns exactly this verb, detached, with
  # stdio into the daemon state dir's log. `daemon stop` is the MANUAL stop
  # path — nothing stops a running daemon behind the operator's back.
  # Failure to boot or stop a daemon is an operator-facing error (exit 4).
  defp dispatch(:daemon, result, _mode) do
    # Optimus FLATTENS the matched subcommand's positionals into result.args:
    # for argv ["daemon", "stop"] the result is %{action: "stop"} — there is
    # no :daemon nesting. (Reading result.args[:daemon][:action] was always
    # nil and routed every daemon verb into the boot arm; the parse shape is
    # pinned by DaemonVerbTest against the real parser below.)
    case result.args[:action] do
      nil ->
        case Boot.run() do
          :ok ->
            # Boot.run parked forever; this arm returns only if parking
            # was interrupted (the VM is going down either way).
            {:ok, :ok}

          {:error, {:already_running, socket_path}} ->
            fail(
              4,
              "error: a daemon is already running at #{socket_path} " <>
                "(stop it with `workstation daemon stop`)"
            )

          {:error, reason} ->
            fail(4, "error: daemon boot failed: #{inspect(reason)}")
        end

      "stop" ->
        case Control.stop() do
          :ok -> {:ok, IO.puts("daemon: stopped")}
          {:error, reason} -> fail(4, "error: daemon stop failed: #{reason}")
        end

      other ->
        fail(2, "error: unknown daemon action #{inspect(other)} (expected: stop)")
    end
  end

  defp dispatch(:apply, result, _mode) do
    home = resolve_home(result)
    adopt = result.flags[:adopt] == true

    # The terminal gate precedes any engine work: a run that cannot proceed
    # interactively must fail with the terminal contract error, not an
    # unrelated engine error discovered while planning.
    cond do
      result.flags[:headless] ->
        pre_replace_stop(home)

        with {:ok, plan} <- apply_plan(result) do
          Plain.run(:apply, destination: home, plan: plan, adopt: adopt)
        end

      usable_terminal?() ->
        pre_replace_stop(home)

        with {:ok, plan} <- apply_plan(result) do
          run_tui(Apply, destination: home, plan: plan, adopt: adopt)
        end

      true ->
        fail(1, @no_terminal)
    end
  end

  defp dispatch(:update, result, _mode) do
    home = resolve_home(result)

    cond do
      # The handoff flag is internal to the release-refresh flow, which
      # always re-execs with --headless; refuse the ambiguous combination
      # instead of silently ignoring the resume list in the TUI.
      result.options[:resume_from] != nil and not result.flags[:headless] ->
        fail(2, "error: --resume-from is an internal handoff flag and requires --headless")

      result.flags[:headless] ->
        # A --resume-from child re-execing after a refresh handoff composes
        # with the daemon's own self-stop: the stop is idempotent daemon-side
        # (the pending-stop marker), so a second request is a no-op and the
        # bounded wait simply observes the same shutdown.
        pre_replace_stop(home)

        with :ok <- fresh_daemon_health_check(result.options[:resume_from], result, home) do
          Plain.run(:update, destination: home, resume_from: result.options[:resume_from])
        end

      usable_terminal?() ->
        pre_replace_stop(home)
        run_tui(Update, destination: home)

      true ->
        fail(1, @no_terminal)
    end
  end

  defp dispatch(other, _result, _mode) do
    fail(2, "error: unknown command #{inspect(other)}")
  end

  # `workstation system applied` — the nix switch drivers' receipt. The
  # driver speaks THIS verb, not the wire protocol: ensure-daemon (spawn on
  # demand), the pinned-home check and the frame codec stay the CLI's one
  # transport contract, and the daemon fans the event out on the `system`
  # overlay domain (Workstation.Daemon.Capabilities.System). Headless by
  # nature — a script-facing receipt, never a TUI surface.
  defp dispatch_system_applied(result) do
    params =
      %{"generation" => result.options[:generation]}
      |> maybe_rollback_generation(result.options[:rollback_generation])

    case DaemonClient.call("system.applied", params, client_opts(result, @read_timeout_ms)) do
      {:ok, record} ->
        {:ok, IO.puts(record["message"])}

      # ensure-daemon's spawn refusal rides as a bare message — engine exit,
      # never a CaseClause crash (same mapping as the lifecycle verbs).
      {:error, message} when is_binary(message) ->
        fail(4, "error: #{message}")

      # The tagged daemon_unavailable tuple (no release binary to spawn, a
      # spawn failure): the daemon_unavailable class is engine exit 4.
      {:error, {tag, message}} when is_atom(tag) ->
        fail(4, "error: #{tag}: #{message}")

      {:error, {code, message}} when is_binary(code) and is_binary(message) ->
        fail(4, "error: #{code}: #{message}")
    end
  end

  defp maybe_rollback_generation(params, nil), do: params

  defp maybe_rollback_generation(params, rollback), do: Map.put(params, "rollback_generation", rollback)

  # Optimus option parser: a strict positive integer (the wire schema's
  # `Zoi.integer(gte: 1)` mirrored at the parse boundary — a usage error
  # here, never a daemon round-trip).
  defp parse_positive_integer(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n >= 1 -> {:ok, n}
      _other -> {:error, "expected a positive integer"}
    end
  end

  ## interactive contract

  # TTY heuristic (r2, recorded): the release VM runs -noshell, where the
  # classic `io:columns/1` probe answers enotsup even on a real PTY and
  # prim_tty:isatty/1 is not callable from user code (badarg; NIF load
  # context). On Linux, procfs exposes what fd 1 actually is: a terminal is
  # /dev/pts/N, /dev/tty* or /dev/console; a redirect is pipe:[..],
  # socket:[..] or /dev/null. Non-Linux or missing /proc reads as NOT a
  # terminal — fail-closed toward the explicit --headless flag, which is the
  # intended contract direction. Known limit: exotic filesystems mounting
  # fd 1 elsewhere read as non-TTY; the --headless escape hatch covers them.
  defp stdout_is_tty? do
    case :file.read_link(~c"/proc/self/fd/1") do
      {:ok, target} ->
        String.match?(List.to_string(target), ~r{^/dev/(pts/\d+|tty[^/]*|console)$})

      _error ->
        false
    end
  end

  @doc """
  The TUI-default contract: interactive verbs engage the TUI only on a real
  terminal with a capable TERM. Without both, the caller must pass
  `--headless` explicitly — the CLI hard-errors otherwise and never degrades
  to the plain runner silently.
  """
  @spec usable_terminal?() :: boolean()
  def usable_terminal? do
    stdout_is_tty?() and capable_term?()
  end

  defp capable_term? do
    case System.get_env("TERM") do
      term when term in [nil, "", "dumb"] -> false
      _term -> true
    end
  end

  # One TUI session, with one documented handoff: a screen that ran the
  # update-availability indicator may ask for the standard update flow
  # (`[u] update`) by sending `{:tui_request, {:run_update, destination}}`
  # to this process (injected as `:tui_caller`) and shutting down. The
  # update screen itself never asks, so the handoff cannot loop.
  defp run_tui(screen, opts) do
    caller = self()

    case TUI.run(screen, Keyword.put_new(opts, :tui_caller, caller)) do
      :ok ->
        case tui_request() do
          {:run_update, destination} -> run_tui(Update, destination: destination)
          nil -> :ok
        end

      {:error, reason} ->
        fail(4, "error: #{screen} failed: #{inspect(reason)}")
    end
  end

  defp tui_request do
    receive do
      {:tui_request, request} -> request
    after
      0 -> nil
    end
  end

  ## read verbs

  # Live reads belong to the daemon: the CLI is a thin client, so the wire
  # is assembled once daemon-side (Workstation.Daemon.Read) and the CLI
  # renders it unchanged. `--input <file>` is the recorded-envelope replay:
  # fully offline (Workstation.CLI.Core), no daemon involved, same wire.
  # Exit codes are unchanged: core evaluation (envelope) failures are
  # precondition (3), daemon unavailability and native collection failures
  # are engine (4).
  defp evaluate(command, home, result) do
    case result.options[:input] do
      nil ->
        case DaemonClient.call(read_op(command), %{}, client_opts(result, @read_timeout_ms)) do
          {:ok, wire} ->
            {:ok, wire}

          {:error, {tag, message}} when is_atom(tag) ->
            # Daemon transport failure: unavailable, died mid-op, or
            # timed out — engine-exit operator error, message verbatim.
            fail(4, "error: #{tag}: #{message}")

          # ensure-daemon's spawn refusal rides as a bare message (no release
          # binary, spawn failure) — engine exit, never a CaseClause crash.
          {:error, message} when is_binary(message) ->
            fail(4, "error: #{message}")

          # The daemon-side read failure classes over the wire: Read's
          # {:core, _}/{:engine, _} arrive as STRING codes (JSON), so a
          # bare-host engine-checkout refusal used to fall through every
          # arm and crash the CLI with a CaseClauseError instead of the
          # intended fail-closed operator error (2026-10-07 shim-anchor
          # gate). Same exit semantics as the offline replay arm: core
          # evaluation failures are precondition (3), engine failures are
          # engine (4).
          {:error, {"core", message}} when is_binary(message) ->
            fail(3, "error: core evaluation failed: #{message}")

          {:error, {"engine", message}} when is_binary(message) ->
            fail(4, "error: #{format_engine_error(message)}")

          {:error, {code, message}} when is_binary(code) and is_binary(message) ->
            # Any other wire refusal keeps the client exit table (locked
            # is precondition, everything else engine) — protocol drift
            # degrades to an operator error, never a crash.
            fail(client_exit(code), "error: #{code}: #{message}")

          {:error, code, message} ->
            fail(client_exit(code), "error: #{code}: #{message}")
        end

      input ->
        case Core.evaluate(command, home, input: input) do
          {:ok, wire} ->
            {:ok, wire}

          {:error, {:core, reason}} ->
            fail(3, "error: core evaluation failed: #{reason}")

          {:error, {:engine, reason}} ->
            fail(4, "error: #{format_engine_error(reason)}")
        end
    end
  end

  defp read_op(:status), do: "status.run"
  defp read_op(:plan), do: "plan.run"
  defp read_op(:diff), do: "diff.run"

  # The apply verb's confirmation plan: the daemon's `apply.plan` op — the
  # SAME composition `apply.run` executes (apply-mode: journal baseline,
  # removal activation, retirements), not the read-mode projection `plan.run`
  # serves. On a home where a declared removal activates (first convergence
  # after a state change) the two generations structurally differ, so a
  # read-mode confirmation would refuse as stale a plan the daemon can build
  # and apply — confirming against `apply.plan` makes the guard's comparison
  # like for like. Error mapping mirrors the read verbs' client contract.
  defp apply_plan(result) do
    case DaemonClient.call("apply.plan", %{}, client_opts(result, @read_timeout_ms)) do
      {:ok, wire} ->
        {:ok, wire}

      {:error, {tag, message}} when is_atom(tag) ->
        # Daemon transport failure: unavailable, died mid-op, or
        # timed out — engine-exit operator error, message verbatim.
        fail(4, "error: #{tag}: #{message}")

      # ensure-daemon's spawn refusal rides as a bare message (no release
      # binary, spawn failure) — an engine-exit operator error, never a crash.
      {:error, message} when is_binary(message) ->
        fail(4, "error: #{message}")

      {:error, {"core", message}} when is_binary(message) ->
        fail(3, "error: core evaluation failed: #{message}")

      {:error, {"engine", message}} when is_binary(message) ->
        fail(4, "error: #{format_engine_error(message)}")

      {:error, {code, message}} when is_binary(code) and is_binary(message) ->
        fail(client_exit(code), "error: #{code}: #{message}")

      {:error, code, message} ->
        fail(client_exit(code), "error: #{code}: #{message}")
    end
  end

  defp lifecycle_op(command), do: "#{command}.run"

  # The release-handoff child's gate: a `--resume-from` run starts AFTER the
  # daemon-side chain refreshed the installed release and the previous
  # daemon stopped itself, so its first ensure-daemon spawn is the
  # replacement generation's node — spawning only once the new release is
  # fully staged (the installer's exit 0 gates the handoff). Before the
  # chain dispatches — before apply proceeds — the lifecycle HEALTH-CHECKS
  # that fresh daemon with one real read op through DaemonClient
  # (`status.run`): the 2026-10-19 aurora incident was a node booted
  # against mid-replacement release files that went on serving corrupt
  # evaluations for every verb, apply included. A normal (non-resume)
  # update skips the extra op — its daemon is proven by its own first op.
  defp fresh_daemon_health_check(nil, _result, _home), do: :ok

  defp fresh_daemon_health_check(_steps, result, _home) do
    case DaemonClient.call("status.run", %{}, client_opts(result, @read_timeout_ms)) do
      {:ok, _wire} ->
        :ok

      {:error, {tag, message}} when is_atom(tag) ->
        fail(4, "error: update health check failed: #{tag}: #{message}")

      {:error, message} when is_binary(message) ->
        fail(4, "error: update health check failed: #{message}")

      {:error, {"core", message}} when is_binary(message) ->
        fail(3, "error: update health check failed: core evaluation failed: #{message}")

      {:error, {"engine", message}} when is_binary(message) ->
        fail(4, "error: update health check failed: #{format_engine_error(message)}")

      {:error, {code, message}} when is_binary(code) and is_binary(message) ->
        fail(client_exit(code), "error: update health check failed: #{code}: #{message}")

      {:error, code, message} ->
        fail(client_exit(code), "error: update health check failed: #{code}: #{message}")
    end
  end

  # The graceful pre-replace stop for the verbs that may replace the
  # installed release (bootstrap/apply/update): a live daemon drains, removes
  # its socket and halts; a refusal or a wedged exit FAILS CLOSED here (exit
  # 4, the engine-failure code) — the verb never proceeds to replace the
  # release under a surviving stale daemon, and never signals the process.
  @spec pre_replace_stop(String.t()) :: :ok
  defp pre_replace_stop(home) do
    case PreReplace.stop_daemon(home: home) do
      :ok -> :ok
      {:error, message} -> fail(4, "error: pre-replace daemon stop failed: #{message}")
    end
  end

  # Client-side daemon failures use the operator vocabulary directly
  # ("daemon_unavailable", "daemon_died", …); `locked` keeps its
  # precondition exit so the lock-contention contract is unchanged.
  defp client_exit("locked"), do: 3
  defp client_exit(_other), do: 4

  defp emit(_command, wire, json: true), do: {:ok, IO.puts(CanonicalJSON.encode(wire))}

  defp emit(command, wire, json: false), do: {:ok, IO.puts(render(command, wire))}

  # The hard-cut read wires are the daemon's .v1 schemas
  # (`Workstation.Daemon.Read.status_schema/0` et al) — plain-text rendering
  # must match the wire the daemon actually answers (the stale `status/1`
  # slash forms matched nothing and crashed every plain `status`).
  defp render(:status, %{"schema" => "workstation.status.v1"} = wire),
    do: Render.core_status(wire)

  defp render(:plan, %{"schema" => "workstation.plan.v1"} = wire), do: Render.core_plan(wire)
  defp render(:diff, %{"schema" => "workstation.diff.v1"} = wire), do: Render.core_diff(wire)

  ## lifecycle plumbing

  # Client-call options: the resolved home the daemon must serve, plus the
  # engine root override riding to the spawn environment (a daemon booted
  # earlier keeps its own environment — documented in the moduledoc).
  defp client_opts(result, timeout_ms) do
    [home: resolve_home(result), timeout_ms: timeout_ms]
    |> put_engine_root(result)
  end

  defp put_engine_root(opts, result) do
    case result.options[:engine_root] do
      nil -> opts
      root -> Keyword.put(opts, :engine_root, Path.expand(root))
    end
  end

  defp emit_record(%{"step" => step, "status" => "ok"} = record) do
    details =
      record
      |> Map.drop(["step", "status"])
      |> Enum.map_join(", ", fn
        {"packages", packages} when is_list(packages) -> "packages=#{length(packages)}"
        {key, value} -> "#{key}=#{value}"
      end)

    {:ok, IO.puts("#{step}: ok" <> if(details == "", do: "", else: " (#{details})"))}
  end

  defp lifecycle_exit("locked"), do: 3

  defp lifecycle_exit(_other), do: 4

  ## plumbing

  defp resolve_home(result) do
    case result.options[:home] do
      nil ->
        case System.get_env("WORKSTATION_HOME") || System.get_env("HOME") do
          home when is_binary(home) and home != "" -> home
          _other -> fail(2, "error: no destination home resolved; pass --home DIR")
        end

      home ->
        Path.expand(home)
    end
  end

  defp format_engine_error(reason) when is_binary(reason), do: reason
  defp format_engine_error(reason), do: "engine failure: #{inspect(reason)}"

  @doc """
  The shared failure surface: one stderr line, then the given exit code.
  Public because the TUI boot path (bare-verb shell) reports its
  daemon-unavailable failure through the exact same contract as the verbs
  (exit 4 — engine failure, daemon unavailable).
  """
  @spec fail(non_neg_integer(), String.t()) :: no_return()
  def fail(exit_code, message) do
    IO.puts(:stderr, String.trim_trailing(message, "\n"))
    exit({:shutdown, exit_code})
  end

  defp format_errors(errors) do
    errors
    |> List.wrap()
    |> Enum.map(&"error: #{&1}")
    |> Enum.join("\n")
  end
end
