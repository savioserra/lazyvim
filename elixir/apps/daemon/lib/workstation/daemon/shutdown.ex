defmodule Workstation.Daemon.Shutdown do
  @moduledoc """
  The daemon's delayed self-stop, used by the surfaces that must stop the
  daemon AFTER a wire reply has flushed:

    * `daemon.stop` op — `workstation daemon stop`, the manual stop path;
    * the lifecycle bootstrap step on a REFRESHED release — the daemon
      wrote the release handoff note, the on-disk release just changed
      under it, and every later op must come from the refreshed code, so
      the daemon stops itself (the client's ensure-daemon re-spawns from
      the refreshed release).

  The stop is always DELAYED: the caller is mid-op inside a session, and
  the reply frame needs a moment on the wire before the supervisor tears
  the socket down. The delay is bounded (no lock is held across it) and
  idempotent — a second request while a stop is pending is a no-op.
  """

  require Logger

  @reply_flush_ms 250

  @doc """
  Schedule a daemon stop `delay_ms` from now (default: just enough for the
  caller's reply frame to flush). Idempotent while a stop is pending.
  """
  @spec stop_after(non_neg_integer(), String.t()) :: :ok
  def stop_after(delay_ms \\ @reply_flush_ms, reason) when is_integer(delay_ms) and is_binary(reason) do
    if :persistent_term.get({__MODULE__, :stopping}, false) do
      :ok
    else
      :persistent_term.put({__MODULE__, :stopping}, true)

      # The test seam (Application env :daemon, :shutdown_hook) replaces the
      # HALT itself, never the bookkeeping: a supervisor-spec test tree
      # cannot let the real System.halt/1 kill the mix run, but the
      # pending-stop idempotency must hold identically (Workstation.Daemon.Shutdown.reset/0
      # clears the marker between tests).
      case Application.get_env(:daemon, :shutdown_hook) do
        hook when is_function(hook, 2) ->
          hook.(delay_ms, reason)

        _real ->
          # Unlinked: the stopping daemon must not die WITH its caller's
          # session — it outlives the op by exactly the flush window.
          spawn(fn ->
            Process.sleep(delay_ms)
            Logger.info("workstation daemon stopping: #{reason}")
            _ = Application.stop(:daemon)
            System.halt(0)
          end)
      end

      :ok
    end
  end

  @doc "Whether a stop has already been scheduled (diagnostics)."
  @spec stopping?() :: boolean()
  def stopping?, do: :persistent_term.get({__MODULE__, :stopping}, false)

  @doc "Clear the pending-stop marker (tests; the real daemon never resets)."
  @spec reset() :: :ok
  def reset, do: :persistent_term.put({__MODULE__, :stopping}, false)
end
