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
  alias Workstation.CLI.DaemonClient
  alias Workstation.CLI.Plain
  alias Workstation.CLI.Render
  alias Workstation.CLI.TUI
  alias Workstation.CLI.TUI.{Apply, Update}
  alias Workstation.CLI.Control
  alias Workstation.Core.CanonicalJSON

  @no_terminal "workstation: no usable terminal; pass --headless for non-interactive runs"

  # Op budget for the read ops; lifecycle calls use the executors' longer
  # budget (lock queues and engine steps take minutes).
  @read_timeout_ms 120_000
  @lifecycle_timeout_ms 600_000

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
          options:
            lifecycle_options() ++
              [
                resume_from: [
                  long: "--resume-from",
                  help: "internal: resume the update chain at these comma-separated steps (set by the release handoff)",
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
        daemon: [
          name: "daemon",
          about: "run the resident daemon in the foreground (ensure-daemon spawns it detached)",
          args: [
            action: [
              value_name: "ACTION",
              nargs: :optional,
              help: "stop — stop a running daemon (the manual stop path)"
            ]
          ]
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
    case DaemonClient.call(lifecycle_op(command), %{}, client_opts(result, @lifecycle_timeout_ms)) do
      {:ok, record} ->
        emit_record(record)

      {:error, {tag, message}} when is_atom(tag) ->
        fail(4, "error: #{tag}: #{message}")

      {:error, code, message} ->
        fail(lifecycle_exit(code), "error: #{code}: #{message}")
    end
  end

  # `daemon stop` is the MANUAL stop path — nothing stops a running daemon
  # behind the operator's back. Failure to reach or stop a daemon is an
  # operator-facing error (exit 4).
  # `daemon stop` is the MANUAL stop path — nothing stops a running daemon
  # behind the operator's back. Failure to reach or stop a daemon is an
  # operator-facing error (exit 4).
  defp dispatch(:daemon, result, _mode) do
    case result.args[:daemon][:action] do
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
      # The handoff flag is internal to the release-refresh flow, which
      # always re-execs with --headless; refuse the ambiguous combination
      # instead of silently ignoring the resume list in the TUI.
      result.options[:resume_from] != nil and not result.flags[:headless] ->
        fail(2, "error: --resume-from is an internal handoff flag and requires --headless")

      result.flags[:headless] ->
        Plain.run(:update, destination: home, resume_from: result.options[:resume_from])

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

  defp lifecycle_op(command), do: "#{command}.run"

  # Client-side daemon failures use the operator vocabulary directly
  # ("daemon_unavailable", "daemon_died", …); `locked` keeps its
  # precondition exit so the lock-contention contract is unchanged.
  defp client_exit("locked"), do: 3
  defp client_exit(_other), do: 4

  defp emit(_command, wire, json: true), do: {:ok, IO.puts(CanonicalJSON.encode(wire))}

  defp emit(command, wire, json: false), do: {:ok, IO.puts(render(command, wire))}

  defp render(:status, %{"schema" => "workstation.status/1"} = wire), do: Render.core_status(wire)
  defp render(:plan, %{"schema" => "workstation.plan/1"} = wire), do: Render.core_plan(wire)
  defp render(:diff, %{"schema" => "workstation.diff/1"} = wire), do: Render.core_diff(wire)

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
