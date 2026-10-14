defmodule Workstation.Daemon.Capabilities.Control do
  @moduledoc """
  The daemon control op: `daemon.stop` — `workstation daemon stop`.

  The manual stop path from the architecture contract ("workstation daemon
  stop stays manual"): an authorized local client (the session peercred
  gate already proved the caller) asks the daemon to stop itself. The stop
  is scheduled through `Workstation.Daemon.Shutdown` AFTER this op's reply
  flushes, so the client receives its `ok` and then observes the socket
  close. The scheduled stop is the GRACEFUL sequence — bounded drain of
  in-flight op tasks (their apply locks release by settling), then the
  socket node's removal, then the halt — which is the contract the
  lifecycle verbs' pre-replace stop (`Workstation.CLI.PreReplace`) waits
  on. Authentication is the daemon's own peercred check; the op adds
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

    # The daemon's OWN OS pid rides the result. The client confirms the beam
    # actually exits after the acknowledged stop, and its kernel peercred
    # read has no pid to give on every platform: darwin's `struct xucred`
    # carries uid/gid only, and a dir-owner-proof generation has no kernel
    # read at all. The wire pid is the platform-independent source; a Linux
    # client keeps preferring its own `SO_PEERCRED` read (pid is the FIRST
    # ucred field) and never needs this field.
    {:ok, %{"stopping" => true, "pid" => String.to_integer(System.pid())}}
  end

  @impl true
  def domains, do: []

  @impl true
  def children, do: []
end
