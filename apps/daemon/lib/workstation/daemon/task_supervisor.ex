defmodule Workstation.Daemon.TaskSupervisor do
  @moduledoc """
  Supervisor of the daemon's op tasks.

  Ops run ASYNC in a task under this supervisor (never in the session
  process) so a long mutation chain does not block the session's frame
  loop: progress events stream while the op runs, and `op.abort` frames
  can still be read. Tasks are spawned `:temporary`-style with
  `Task.Supervisor.start_child/2` — a crashed task reports the op failure
  to its session and dies here without restarting (a HALF-run mutation
  must never be silently retried by a supervisor; the client decides what
  happens next). The session links nothing: a disconnecting client
  DETACHES — the daemon-side run survives and finishes under its lock,
  exactly the detach contract the one-shot era had with a Ctrl-C'd parent.
  """

  @doc false
  def child_spec(_opts) do
    Supervisor.child_spec({Task.Supervisor, name: __MODULE__}, id: __MODULE__)
  end
end
