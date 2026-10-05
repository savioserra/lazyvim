defmodule Workstation.CLI.Router do
  @moduledoc """
  `workstation` command line (optimus) for the read-only front end.

  Subcommands `status`, `plan`, and `diff` render one hard-cut output schema
  per command (`Workstation.CLI.Output`), evaluated in-process through the
  Elixir core (`Workstation.CLI.Core`). The evaluated catalog is the native
  live envelope (`Workstation.Core.Catalog.live/1`) — no external engine
  process; `--input <file>` substitutes a recorded golden envelope for
  offline replay.

  `json <command>` is the machine form: canonical JSON of the hard-cut wire,
  one document on stdout.

  Safety contract (hard requirement carried over from the strangler window):
  evaluation may write journal state under whatever `HOME` it is pointed
  at, so the CLI never runs against the real home directory. `--home` is
  mandatory, must not equal the real `$HOME`, and must carry the
  `.workstation-test-root` marker created by `.github/scripts/test-home.sh`.

  Exit codes (docs/elixir.md carries the table): 0 ok; 2 usage; 3
  conflict-or-precondition (core evaluation failed: bad envelope, graph or
  plan conflict, invariant); 4 engine failure (native collection error:
  unresolved engine checkout, missing or empty package asset); 77 refused
  home (real `$HOME` or missing test-root marker).
  """

  alias Workstation.CLI.Core
  alias Workstation.CLI.Render
  alias Workstation.Core.CanonicalJSON

  @test_root_marker ".workstation-test-root"

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
      description: "Read-only front end over the workstation Lua engine (lane b3).",
      allow_unknown_args: false,
      parse_double_dash: true,
      subcommands: [
        status: [
          name: "status",
          about: "engine status report",
          options: subcommand_options(),
        ],
        plan: [
          name: "plan",
          about: "engine plan report",
          options: subcommand_options(),
        ],
        diff: [
          name: "diff",
          about: "engine diff report",
          options: subcommand_options(),
        ],
        json: [
          name: "json",
          about: "emit the engine JSON wire report unchanged",
          subcommands: [
            status: [
              name: "status",
              about: "raw status JSON",
              options: subcommand_options(),
            ],
            plan: [
              name: "plan",
              about: "raw plan JSON",
              options: subcommand_options(),
            ],
            diff: [
              name: "diff",
              about: "raw diff JSON",
              options: subcommand_options(),
            ]
          ]
        ]
      ]
    )
  end

  defp subcommand_options do
    [
      home: [
        value_name: "DIR",
        long: "--home",
        help: "private test home created by .github/scripts/test-home.sh (mandatory)",
        required: true
      ],
      input: [
        value_name: "FILE",
        long: "--input",
        help: "plan replay: recorded golden input.json instead of the live native catalog"
      ]
    ]
  end

  ## dispatch

  defp dispatch_from_result(_result), do: {:ok, IO.puts(Optimus.help(parser()))}

  defp dispatch(command, result, mode) when command in [:status, :plan, :diff] do
    home = result.options.home

    with :ok <- guard_real_home(home),
         :ok <- guard_test_root(home),
         {:ok, wire} <- evaluate(command, home, result),
         :ok <- emit(command, wire, mode) do
      :ok
    end
  end

  defp dispatch(other, _result, _mode) do
    fail(2, "error: unknown command #{inspect(other)}")
  end

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

  defp format_engine_error(reason) when is_binary(reason), do: reason
  defp format_engine_error(reason), do: "engine failure: #{inspect(reason)}"

  ## safety guards

  @doc """
  Refuse when the requested home is the real `$HOME` (compared by device
  and inode, so symlinks and aliases are caught). The engine mutates its
  home, so it must never see the operator's actual home directory.
  """
  def real_home_guard_path, do: System.get_env("HOME") || ""

  defp guard_real_home(home) do
    if same_file?(home, real_home_guard_path()) do
      fail(77, """
      error: refusing --home #{home}: equals the real $HOME
      create a private test root with: sh .github/scripts/test-home.sh
      """)
    else
      :ok
    end
  end

  @doc "Marker file name written by .github/scripts/test-home.sh inside the test root."
  def test_root_marker, do: @test_root_marker

  defp guard_test_root(home) do
    marker = Path.join(resolve_path(home), @test_root_marker)

    if File.exists?(marker) do
      :ok
    else
      fail(77, """
      error: refusing --home #{home}: missing #{@test_root_marker} marker
      create it with: sh .github/scripts/test-home.sh
      """)
    end
  end

  ## plumbing

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

  defp resolve_path(""), do: ""

  defp resolve_path(path), do: Path.expand(path)

  # Symlink-safe "same directory" identity: compare device and inode.
  defp same_file?(_a, ""), do: false

  defp same_file?(a, b) do
    case {file_identity(a), file_identity(b)} do
      {{:ok, id}, {:ok, id}} -> true
      _ -> false
    end
  end

  defp file_identity(path) do
    case File.stat(path) do
      {:ok, %{major_device: device, inode: inode}} -> {:ok, {device, inode}}
      {:error, _} -> :error
    end
  end
end
