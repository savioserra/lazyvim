defmodule Workstation.CLI.Router do
  @moduledoc """
  `workstation` command line — the fused front door of the engine.

  The read plane serves the BAKED EVAL REPORT in-process
  (`Workstation.CLI.Output` — the flake's `evalReport` fold, cached into the
  release at `share/workstation/eval-report.json`; the same bytes
  `nix eval .#evalReport.<system>` answers). Every read verb (`status`,
  `plan`, `capabilities`, `json <command>`) evaluates the report for the
  resolved destination and renders it. There is no resident engine process
  and no socket: the daemon and its wire protocol retired with the read
  plane's move to the cached eval surface. The write plane lives in the nix
  substrate: mutation is the `workstation-switch` drivers
  (apply/rollback/update/sync), and the driver's switch-time receipt lands
  in the state tree's `switch.log` — the activation hooks carry every
  event; nothing publishes through the engine.

  `-h/--help` is a global flag: every subcommand answers it with its usage
  and exit 0 BEFORE any dispatch — a help request never resolves a home,
  checks a terminal, or runs the verb (the 2026-10-19 aurora incident:
  `bootstrap --help` ran a real provisioning pass on a release that
  silently ignored the flag). Unknown flags are a usage error (exit 2) —
  never silently ignored.

  `--home` selects the destination home (default: `$WORKSTATION_HOME`, else
  `$HOME` — the launcher shim rebases both to the same destination, so verbs
  address the intended home either way).

  Exit codes (docs/elixir.md carries the table): 0 ok; 1 no usable terminal
  for an interactive verb; 2 usage; 3 conflict-or-precondition (evaluation
  failure); 4 engine failure (missing or malformed report).
  """

  alias Workstation.CLI.Capabilities
  alias Workstation.CLI.Output
  alias Workstation.CLI.Render
  alias Workstation.CLI.TUI
  alias Workstation.Core.CanonicalJSON

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

  # Public for the parse-shape regressions (the read verbs' flattened
  # positionals pin through THIS spec, not a copy).
  def parser do
    Optimus.new!(
      name: "workstation",
      description:
        "workstation engine front end: reads answer from the baked eval report, the nix substrate mutates.",
      allow_unknown_args: false,
      parse_double_dash: true,
      # The global help flag: Optimus merges a `global` flag into EVERY
      # subcommand (hidden from their help), so `-h/--help` parses on any
      # invocation and the dispatch gate answers it before the verb runs —
      # without it, the flag landed in unknown-args (a usage error where it
      # was silently ignored on releases pre fail-closed: the aurora
      # `bootstrap --help` execution).
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
      ]
    ]
  end

  # Scope flags of the grouped `capabilities` listing: drill to one domain
  # (docs/capabilities.md naming: base, fonts, runtime, editor, terminal,
  # theme, agent, secrets) or one capability inside its domain.
  defp scope_options do
    [
      domain: [
        value_name: "DOMAIN",
        long: "--domain",
        help: "scope the listing to one capability domain (e.g. editor)"
      ],
      capability: [
        value_name: "CAPABILITY",
        long: "--capability",
        help: "scope the listing to one capability (implies target drill-down)"
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

  ## help contract

  # The dispatch gate: `-h/--help` on ANY invocation prints the invoking
  # command's usage and exits 0. The gate runs before EVERY side effect —
  # home resolution and the terminal check included — so a help request can
  # never resolve state.
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
      TUI.Shell.run(destination: home, preset: preset)
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

  defp dispatch(command, result, mode) when command in [:status, :plan] do
    # resolve (and validate) the destination first: an unresolvable home is
    # a usage error before any read
    home = resolve_home(result)

    with {:ok, wire} <- evaluate(command, home),
         :ok <- emit(command, wire, mode) do
      :ok
    end
  end

  # The grouped capabilities verb: TWO reads folded by
  # `Workstation.CLI.Capabilities` (the accounting rows from the status
  # wire, the target states from the plan wire). Informational output —
  # stays exit 0, matching the read verbs' drift-free contract.
  defp dispatch(:capabilities, result, _mode) do
    home = resolve_home(result)

    with {:ok, status} <- evaluate(:status, home),
         {:ok, plan} <- evaluate(:plan, home) do
      envelope =
        %{"status" => status, "plan" => plan}
        |> Capabilities.group()
        |> Capabilities.scope(domain: result.options[:domain], capability: result.options[:capability])

      if result.flags[:json] do
        {:ok, IO.puts(CanonicalJSON.encode(envelope))}
      else
        {:ok,
         IO.puts(
           Render.capabilities(
             envelope,
             domain: result.options[:domain],
             capability: result.options[:capability],
             files: result.flags[:files] == true
           )
         )}
      end
    end
  end

  defp dispatch(other, _result, _mode) do
    fail(2, "error: unknown command #{inspect(other)}")
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

  # One TUI session. The bare-verb shell is the only remaining screen host;
  # the standalone apply/update screens retired with the engine's write
  # plane (mutation is the `workstation-switch` drivers now).

  ## read verbs

  # The read plane answers in-process from the baked report
  # (`Workstation.CLI.Output`); the CLI renders the wire unchanged. Exit
  # codes are unchanged: core evaluation failures are precondition (3),
  # a missing or malformed report is engine (4).
  defp evaluate(command, home) do
    case Output.evaluate(command, home) do
      {:ok, wire} ->
        {:ok, wire}

      # The read's probe failure classes: core evaluation failures are
      # precondition (3), report failures are engine (4) — the operator
      # exit table, unchanged from the wire era.
      {:error, {:core, message}} when is_binary(message) ->
        fail(3, "error: core evaluation failed: #{message}")

      {:error, {:engine, message}} when is_binary(message) ->
        fail(4, "error: #{message}")
    end
  end

  defp emit(_command, wire, json: true), do: {:ok, IO.puts(CanonicalJSON.encode(wire))}

  defp emit(command, wire, json: false), do: {:ok, IO.puts(render(command, wire))}

  # The hard-cut read wires are the Output schemas (`workstation.status.v2`
  # / `workstation.plan.v2`) — plain-text rendering must match the wire the
  # read actually answers.
  defp render(:status, %{"schema" => "workstation.status.v2"} = wire),
    do: Render.core_status(wire)

  defp render(:plan, %{"schema" => "workstation.plan.v2"} = wire), do: Render.core_plan(wire)

  ## plumbing

  @doc """
  The destination-home resolution precedence: the `--home` flag, else
  `$WORKSTATION_HOME`, else `$HOME`; none resolvable is a usage error
  (exit 2). Public so the resolution contract is pinnable without a
  daemon (the launcher shim rebases flag and env to one destination).
  """
  def resolve_home(result) do
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

  @doc """
  The shared failure surface: one stderr line, then the given exit code.
  Public because the TUI boot path (bare-verb shell) reports its failures
  through the exact same contract as the verbs.
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
