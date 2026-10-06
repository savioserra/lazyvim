defmodule Workstation.Daemon.Capabilities.Read do
  @moduledoc """
  Wire surface of the read engine: `status.run`, `plan.run`, `diff.run`.

  Params are empty by design — the daemon serves its own pinned home (the
  home it booted with), and a client that needs a different destination
  stops this daemon and lets ensure-daemon spawn one for that home. The
  result is the hard-cut read wire (`Workstation.Daemon.Read`), byte-for-
  byte the shape the CLI renders; read failures keep the engine's
  `core`/`engine` error vocabulary so the client's exit-code contract is
  unchanged.
  """

  @behaviour Workstation.Daemon.Capability

  alias Workstation.Core.EngineState
  alias Workstation.Daemon.Read

  @empty_schema Zoi.object(%{}, unrecognized_keys: :error)

  @impl true
  def ops, do: ["diff.run", "plan.run", "status.run"]

  @impl true
  def schema("status.run"), do: @empty_schema
  def schema("plan.run"), do: @empty_schema
  def schema("diff.run"), do: @empty_schema

  @impl true
  def handle(op, _params, _ctx) do
    command =
      case op do
        "status.run" -> :status
        "plan.run" -> :plan
        "diff.run" -> :diff
      end

    case Read.evaluate(command, EngineState.home(), input: nil) do
      {:ok, wire} -> {:ok, wire}
      {:error, {tag, reason}} -> {:error, {Atom.to_string(tag), reason}}
    end
  end

  @impl true
  def domains, do: []

  @impl true
  def children, do: []
end
