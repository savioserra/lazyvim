defmodule Workstation.CLI.Router do
  @moduledoc """
  `workstation` command line — the fused front door of the engine.

  Read verbs (`status`, `plan`, `diff`, `json <command>`) evaluate the live
  native catalog in-process (`Workstation.CLI.Core`) and render one hard-cut
  output schema per command (`Workstation.CLI.Output`); `--input <file>`
  substitutes a recorded golden envelope for offline replay.

  Lifecycle verbs run the engine in this process (`Workstation.CLI.Engine`):
  `bootstrap`, `apply`, `update`, `sync`, `verify`, `pull`. `apply` and
  `update` are interactive-first — the TUI is the DEFAULT for verbs with a
  screen, and there is no silent degradation: on a usable terminal they run
  the TUI screens; `--headless` forces the plain runner; a non-terminal
  stdout WITHOUT `--headless` is a hard error, never a plain fallback. The
  other lifecycle verbs are plain runs by nature (no screen exists).

  `--home` selects the destination home (default: `$WORKSTATION_HOME`, else
  `$HOME` — the launcher shim rebases both to the same destination, so verbs
  address the intended home either way). `--engine-root` selects the engine
  checkout for the bootstrap/update steps (default: `$WORKSTATION_ENGINE_REPO`,
  else checkout-walk detection).

  Exit codes (docs/elixir.md carries the table): 0 ok; 1 no usable terminal
  for an interactive verb; 2 usage; 3 conflict-or-precondition (evaluation
  failure or apply-lock contention); 4 engine failure (native collection
  error, lifecycle step failure).
  """

  alias Workstation.CLI.Core
  alias Workstation.CLI.Engine
  alias Workstation.CLI.Plain
  alias Workstation.CLI.Render
  alias Workstation.CLI.TUI
  alias Workstation.CLI.TUI.{Apply, Update}
  alias Workstation.Core.CanonicalJSON

  @no_terminal "workstation: no usable terminal; pass --headless for non-interactive runs"

  def main(argv) do
    case Optimus.parse(parser(), argv) do
      {:ok, result} ->
        dispatch_from_result(result)

      {:ok, [:json, command], result} ->
        dispatch(command, result, json: true)

      {:ok, [command], result} ->
        dispatch(command, result, json: false)

      {:error, errors} ->
        fail(2, format_errors(errors))

      {:error, _subcommand_path, errors} ->
        fail(2, format_errors(errors))
      :version ->
        {:ok, IO.puts("workstation #{Application.spec(:cli, :vsn) || "0.0.0"}")}

      :help ->
        {:ok, IO.puts(Optimus.help(parser()))}

      {:help, _path} ->
        {:ok, IO.puts(Optimus.help(parser()))}
    end
  end

  ## parser

  defp parser do
    Optimus.new!(
      name: "workstation",
      description: "workstation engine front end: read verbs report, lifecycle verbs mutate.",
      allow_unknown_args: false,
      parse_double_dash: true,
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
          flags: [headless: [long: "--headless", help: "force the non-interactive plain runner"]]
        ],
        update: [
          name: "update",
          about: "pull, bootstrap, apply, sync, verify — abort on first failure (TUI by default)",
          options: lifecycle_options(),
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
        ]
      ]
    )
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
        help: "engine checkout for bootstrap/update (default: $WORKSTATION_ENGINE_REPO, else detection)"
      ]
    ]
  end

  ## dispatch

  defp dispatch_from_result(_result), do: {:ok, IO.puts(Optimus.help(parser()))}

  defp dispatch(command, result, mode) when command in [:status, :plan, :diff] do
    home = resolve_home(result)

    with {:ok, wire} <- evaluate(command, home, result),
         :ok <- emit(command, wire, mode) do
      :ok
    end
  end

  defp dispatch(command, result, _mode) when command in [:bootstrap, :sync, :verify, :pull] do
    case apply(Engine, command, [lifecycle_opts(result)]) do
      {:ok, record} -> emit_record(record)
      {:error, code, message} -> fail(lifecycle_exit(code), "error: #{code}: #{message}")
    end
  end

  defp dispatch(:apply, result, _mode) do
    home = resolve_home(result)

    # The terminal gate precedes any engine work: a run that cannot proceed
    # interactively must fail with the terminal contract error, not an
    # unrelated engine error discovered while planning.
    cond do
      result.flags[:headless] ->
        with {:ok, plan} <- evaluate(:plan, home, result) do
          Plain.run(:apply, destination: home, plan: plan)
        end

      usable_terminal?() ->
        with {:ok, plan} <- evaluate(:plan, home, result) do
          run_tui(Apply, destination: home, plan: plan)
        end

      true ->
        fail(1, @no_terminal)
    end
  end

  defp dispatch(:update, result, _mode) do
    home = resolve_home(result)

    cond do
      result.flags[:headless] ->
        Plain.run(:update, destination: home)

      usable_terminal?() ->
        run_tui(Update, destination: home)

      true ->
        fail(1, @no_terminal)
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

  defp run_tui(screen, opts) do
    case TUI.run(screen, opts) do
      :ok -> :ok
      {:error, reason} -> fail(4, "error: #{screen} failed: #{inspect(reason)}")
    end
  end

  ## read verbs

  # The core is the only front end; json mode emits canonical bytes of the
  # wire. Engine-tagged failures are native collection failures (see the
  # exit-code contract in the moduledoc).
  defp evaluate(command, home, result) do
    case Core.evaluate(command, home, input: result.options[:input]) do
      {:ok, wire} -> {:ok, wire}
      {:error, {:core, reason}} -> fail(3, "error: core evaluation failed: #{reason}")
      {:error, {:engine, reason}} -> fail(4, "error: #{format_engine_error(reason)}")
    end
  end

  defp emit(_command, wire, json: true), do: {:ok, IO.puts(CanonicalJSON.encode(wire))}

  defp emit(command, wire, json: false), do: {:ok, IO.puts(render(command, wire))}

  defp render(:status, %{"schema" => "workstation.status.v1"} = wire), do: Render.core_status(wire)
  defp render(:plan, %{"schema" => "workstation.plan.v1"} = wire), do: Render.core_plan(wire)
  defp render(:diff, %{"schema" => "workstation.diff.v1"} = wire), do: Render.core_diff(wire)

  ## lifecycle plumbing

  defp lifecycle_opts(result) do
    home = resolve_home(result)

    [home: home]
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

    {:ok, IO.puts("#{step}: ok" <> (if details == "", do: "", else: " (#{details})"))}
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

  defp fail(exit_code, message) do
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
