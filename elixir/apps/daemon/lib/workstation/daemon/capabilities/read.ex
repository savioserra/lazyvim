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
  alias Workstation.Daemon.{Read, UpdateCheck}

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
      {:ok, wire} -> {:ok, merge_update_availability(command, wire)}
      {:error, {tag, reason}} -> {:error, {Atom.to_string(tag), reason}}
    end
  end

  # The status wire gains `update` when the (TTL-cached) availability check
  # RESOLVES — `true`/`false` with the shas when behind — and stays ABSENT
  # when the verdict is unknown: offline must look like no-news, never like
  # a difference, and byte-stability of the wire for the no-check case is
  # what the golden and offline-replay contracts were written against. The
  # merge is status-only and daemon-only (offline --input replay never
  # consults the network).
  defp merge_update_availability(:status, wire) do
    case Application.get_env(:daemon, :update_check, false) && UpdateCheck.check_cached() do
      %{
        "status" => "behind",
        "local" => local,
        "remote" => remote,
        "remote_ref" => remote_ref
      } ->
        Map.put(wire, "update", %{"available" => true, "local" => local, "remote" => remote, "remote_ref" => remote_ref})

      %{"status" => "up_to_date"} ->
        Map.put(wire, "update", %{"available" => false})

      _unknown_or_disabled ->
        wire
    end
  end

  defp merge_update_availability(_other, wire), do: wire

  @impl true
  def domains, do: []

  @impl true
  def children, do: []
end
