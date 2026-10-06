defmodule Workstation.CLI.Core do
  @moduledoc """
  The CLI's OFFLINE replay path — the one in-process read surface left
  after the client/server refactor.

  Live reads (`status`, `plan`, `diff` without `--input`) belong to the
  daemon: the Router routes them through `Workstation.CLI.DaemonClient`
  (`status.run` / `plan.run` / `diff.run`) and the wire is assembled once,
  daemon-side, in `Workstation.Daemon.Read`. This module exists only for
  `--input <file>`: a recorded golden envelope substitutes for the live
  catalog, making evaluation fully offline and file-driven — the golden
  parity tests rely on it, and an offline replay needs no daemon at all.

  The envelope is read and JSON-decoded here, then handed to
  `Workstation.Daemon.Read` as `input: {:file, envelope}` — one wire
  source, two transport paths.

  State-root bracketing: the core reads journal state through
  `Workstation.Core.EngineState.home/0` (`WORKSTATION_HOME`). This module
  brackets that variable around the offline evaluation and restores the
  previous value, so a replay always sees exactly the selected `--home`
  and never the operator's real state root. The bracket is process-global
  and brief.
  """

  alias Workstation.Daemon.Read

  @type error :: {:error, {:core, String.t()}} | {:error, {:engine, String.t()}}

  @doc """
  Evaluate one command against a RECORDED envelope (`opts[:input]`, a path
  to recorded golden `input.json`). Returns `{:ok, wire}` with the hard-cut
  schema for the command, or an error tagged `{:core, reason}` (unreadable
  or invalid envelope) — the caller's usage-or-conflict exit.

  Live (daemon-backed) evaluation is the Router's daemon route; calling
  this module without `:input` is a programming error and refuses loudly
  instead of silently re-implementing the daemon path.
  """
  @spec evaluate(atom(), String.t(), keyword()) :: {:ok, map()} | error()
  def evaluate(command, home, opts) when command in [:status, :plan, :diff] do
    expanded = Path.expand(home)

    with {:ok, decoded} <- load_input Keyword.fetch!(opts, :input) do
      bracket(expanded, fn ->
        Read.evaluate(command, expanded, input: {:file, decoded})
      end)
    end
  end

  ## input collection

  # The replay input is always a file: decode errors are core errors (bad
  # envelope), never engine failures.
  defp load_input(input_path) when is_binary(input_path) do
    path = Path.expand(input_path)

    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents) do
      {:ok, decoded}
    else
      {:error, %Jason.DecodeError{} = reason} ->
        {:error, {:core, "invalid input envelope #{path}: #{Exception.message(reason)}"}}

      {:error, reason} ->
        {:error, {:core, "cannot read input envelope #{path}: #{inspect(reason)}"}}
    end
  end

  ## state-root bracket

  defp bracket(home, fun) do
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    try do
      fun.()
    after
      restore_state_root(previous)
    end
  end

  defp restore_state_root(nil), do: System.delete_env("WORKSTATION_HOME")
  defp restore_state_root(previous), do: System.put_env("WORKSTATION_HOME", previous)
end
