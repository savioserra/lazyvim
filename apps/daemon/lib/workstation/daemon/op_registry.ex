defmodule Workstation.Daemon.OpRegistry do
  @moduledoc """
  Live in-flight op index: `op_ref -> running op task pid` (a `:unique`
  registry — one abort target per op run).

  Why a registry and not session state: aborts must work across sessions —
  the streaming client holds its op on ONE connection, but the abort
  request (`op.abort`) may arrive on ANOTHER (the TUI cannot write to the
  runner's socket, and a headless operator may abort from a second
  terminal). The op task registers itself on start
  (`Workstation.Daemon.Events.register/1`) and unregisters on settle;
  registry cleanup on process death keeps a crashed task from staying
  abortable forever.
  """

  @doc false
  def child_spec(_opts) do
    Supervisor.child_spec(
      {Registry, keys: :unique, name: Workstation.Daemon.OpRegistry},
      id: __MODULE__
    )
  end
end
