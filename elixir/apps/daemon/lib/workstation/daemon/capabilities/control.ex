defmodule Workstation.Daemon.Capabilities.Control do
  @moduledoc """
  The daemon control op: `daemon.stop` — `workstation daemon stop`.

  The manual stop path from the architecture contract ("workstation daemon
  stop stays manual"): an authorized local client (the session peercred
  gate already proved the caller) asks the daemon to stop itself. The stop
  is scheduled through `Workstation.Daemon.Shutdown` AFTER this op's reply
  flushes, so the client receives its `ok` and then observes the socket
  close. Authentication is the daemon's own peercred check; the op adds
  nothing to it.
  """

  @behaviour Workstation.Daemon.Capability

  alias Workstation.Daemon.Shutdown

  @empty_schema Zoi.object(%{}, unrecognized_keys: :error)

  @impl true
  def ops, do: ["daemon.stop"]

  @impl true
  def schema("daemon.stop"), do: @empty_schema

  @impl true
  def handle("daemon.stop", _params, _ctx) do
    :ok = Shutdown.stop_after("daemon.stop op")
    {:ok, %{"stopping" => true}}
  end

  @impl true
  def domains, do: []

  @impl true
  def children, do: []
end
