defmodule Workstation.CLI.Output do
  @moduledoc """
  Hard-cut CLI output wire schemas: exactly one schema per
  command, versioned, never reshaped by a caller. The builders moved to
  `Workstation.Daemon.Read` in the client/server refactor — the daemon is
  the single wire source (its read ops return these maps; the CLI renders
  them unchanged) — and this module keeps the same public builders as thin
  delegates so CLI-side callers and tests keep one spelling.
  """

  @delegee Workstation.Daemon.Read

  @doc "Schema identifier of the hard-cut status wire."
  def status_schema, do: @delegee.status_schema()

  @doc "Schema identifier of the hard-cut plan wire."
  def plan_schema, do: @delegee.plan_schema()

  @doc "Build the status wire. See `Workstation.Daemon.Read.status/2`."
  defdelegate status(destination, report), to: @delegee

  @doc "Build the plan wire. See `Workstation.Daemon.Read.plan/2`."
  defdelegate plan(destination, report), to: @delegee
end