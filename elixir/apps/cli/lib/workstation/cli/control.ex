defmodule Workstation.CLI.Control do
  @moduledoc """
  The `workstation daemon stop` client: the MANUAL stop path. Nothing in
  the engine stops a daemon behind the operator's back — a stop is always
  operator-initiated, either directly (this module, via the control frame)
  or indirectly (the daemon's own release-refresh handoff stop).

  The frame is one-way and unauthenticated by design: possession of the
  socket already implies the same uid (peercred authorizes every session),
  so an extra handshake would add ceremony, not security. A daemon that
  ignores or never sees the frame keeps running — the operator can always
  verify with any verb.
  """

  alias Workstation.CLI.DaemonClient

  @doc """
  Ask the resident daemon to stop. Returns `:ok` when the daemon
  acknowledged (it then exits after flushing the reply), or
  `{:error, reason}` when no daemon could be reached.
  """
  @spec stop() :: :ok | {:error, String.t()}
  def stop do
    # The op's wire result is %{{"stopping" => true}} — a plain `:ok` arm
    # can never match and would crash the operator's stop with a
    # CaseClauseError exactly when it succeeded.
    case DaemonClient.control("daemon.stop") do
      {:ok, %{"stopping" => true}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
