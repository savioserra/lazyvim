defmodule Workstation.Daemon.Application do
  @moduledoc """
  Daemon supervision tree.

  `:rest_for_one` and the fixed child order (Listener → Sessions → EventBus →
  CapabilityRegistry → ApplyOrchestrator → capability children) encode the
  daemon's failure-mode contract: every runtime dependency flows strictly
  forward (a Session talks to EventBus, CapabilityRegistry and the
  capabilities; the Listener hands sockets to Sessions), so any crash rolls
  the whole serving generation and rebuilds it in dependency order. A
  backward dependency would either deadlock the restart or resurrect
  processes whose dependents are still dead.

  Infrastructure children are central and fixed; the capability layer's
  children (`Workstation.Daemon.Capabilities.children/0`) are flattened in
  AFTER them, so a capability child starts after the registry it depends on
  and — under `:rest_for_one` — never outlives it. `OpRegistry` and
  `TaskSupervisor` sit with the infrastructure: op tasks are the daemon's
  serving machinery, not a capability's private helper. The Listener
  restarts by
  closing and re-binding its socket — takeover probes a live peer and fails
  with `:already_running` when another generation really is serving, so an
  overlap window cannot produce two daemons on one socket path.
  """

  use Application

  alias Workstation.Daemon.Capabilities

  @infrastructure [
    Workstation.Daemon.Listener,
    Workstation.Daemon.Sessions,
    Workstation.Daemon.EventBus,
    Workstation.Daemon.OpRegistry,
    Workstation.Daemon.CapabilityRegistry,
    Workstation.Daemon.ApplyOrchestrator,
    Workstation.Daemon.TaskSupervisor
  ]

  @doc "The tree children in rest_for_one order (shared by boot and tests)."
  @spec children() :: [Supervisor.child_spec() | module()]
  def children do
    @infrastructure ++ Capabilities.children()
  end

  @doc """
  Standalone supervisor child-spec for the whole tree (default name
  `Workstation.Daemon.Supervisor`). The daemon entrypoint and the tests boot
  EXACTLY this spec, so a test generation and a production generation are
  wired identically — including the rest_for_one order the suite asserts.
  """
  @spec supervisor_spec(keyword()) :: Supervisor.child_spec()
  def supervisor_spec(opts \\ []) do
    name = Keyword.get(opts, :name, Workstation.Daemon.Supervisor)

    %{
      id: name,
      start: {Supervisor, :start_link, [children(), [strategy: :rest_for_one, name: name]]},
      type: :supervisor
    }
  end

  @impl true
  def start(_type, _args) do
    # No ets/registry priming is needed before boot: EventBus owns its own
    # registry and every child is self-contained.
    Supervisor.start_link(children(), name: Workstation.Daemon.Supervisor, strategy: :rest_for_one)
  end
end
