defmodule Workstation.Daemon.Shutdown do
  # Declared before the moduledoc so the doc can interpolate the real budget.
  @reply_flush_ms 250
  @drain_timeout_ms 30_000
  @drain_poll_ms 50

  @moduledoc """
  The daemon's GRACEFUL self-stop, used by the surfaces that must stop the
  daemon AFTER a wire reply has flushed:

    * `daemon.stop` op — `workstation daemon stop`, the manual stop path,
      and the lifecycle verbs' pre-replace stop (`Workstation.CLI.PreReplace`);
    * the lifecycle bootstrap step on a REFRESHED release — the daemon
      wrote the release handoff note, the on-disk release just changed
      under it, and every later op must come from the refreshed code, so
      the daemon stops itself (the client's ensure-daemon re-spawns from
      the refreshed release).

  The stop is always DELAYED past the caller's reply: the caller is mid-op
  inside a session, and the reply frame needs a moment on the wire before
  the shutdown sequence starts. The sequence after the flush window is the
  graceful contract the lifecycle verbs depend on:

    1. DRAIN — wait, bounded (`:drain_timeout_ms`, default
       #{@drain_timeout_ms |> div(1_000)}s), for every in-flight op task
       under `Workstation.Daemon.TaskSupervisor` to settle. A settling op
       releases its own apply lock (`Workstation.Core.ApplyLock` — the
       holder removes the file itself inside the op's lock scope), so a
       drained stop never leaves the "apply lock not released cleanly"
       debris a kill leaves. A drain that outlives its budget logs and
       proceeds — the stop is never unbounded, and a lock left behind by an
       interrupted op is fail-closed operator recovery (stale locks are
       never stolen), named in the log.
    2. REMOVE THE SOCKET — unlink the socket node after the no-follow
       owned-socket proof (`Workstation.Daemon.Listener.owned_socket?/1`).
       Existing sessions keep their established connections; new connects
       by path fail immediately, which is exactly the observable the CLI's
       pre-replace wait polls. The listening socket itself dies with the
       supervisor teardown right after.
    3. EXIT — `Application.stop(:daemon)` then `System.halt(0)`.

  The sequence is idempotent — a second request while a stop is pending is
  a no-op (the pending-marker check), which is what lets a pre-replace stop
  compose with the release-refresh handoff stop without fighting it.
  """

  require Logger

  alias Workstation.Daemon.{Listener, TaskSupervisor}

  @doc """
  Schedule a graceful daemon stop `delay_ms` from now (default: just enough
  for the caller's reply frame to flush). Idempotent while a stop is pending.
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
      # clears the marker between tests). The graceful sequence (drain +
      # socket removal) runs for real on both paths — the in-process test
      # tree observes the same observable (socket gone) the production
      # client waits for; only the halt is replaced.
      case Application.get_env(:daemon, :shutdown_hook) do
        hook when is_function(hook, 2) ->
          drain_ops!()
          remove_socket!()
          hook.(delay_ms, reason)

        _real ->
          # Unlinked: the stopping daemon must not die WITH its caller's
          # session — it outlives the op by the flush window plus the drain.
          spawn(fn ->
            Process.sleep(delay_ms)
            drain_ops!()
            remove_socket!()
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

  ## graceful sequence -------------------------------------------------------

  # Bounded wait for every in-flight op task to settle. The caller's own
  # task (the inline test-seam path runs INSIDE the scheduling op) never
  # counts against the drain — excluding self() is exactly "wait for the
  # OTHERS"; the spawned real path is not a task, so everything counts.
  # A supervisor-less context (CLI one-shot, plain unit tests) has no tasks
  # to wait for at all.
  defp drain_ops! do
    deadline = monotonic_ms() + drain_budget()

    case in_flight_tasks() do
      [] ->
        :ok

      tasks ->
        Logger.info("daemon stop: draining #{length(tasks)} in-flight op task(s)")
        await_drain(deadline)
    end
  end

  defp await_drain(deadline) do
    cond do
      in_flight_tasks() == [] ->
        :ok

      # Not a fresh liveness check — the budget bounds the WHOLE drain, so a
      # trickle of new tasks cannot extend it past the stop.
      monotonic_ms() >= deadline ->
        Logger.warning(
          "daemon stop: drain budget spent with op task(s) still in flight; stopping anyway — " <>
            "an interrupted op may leave its apply lock in place (stale locks are never stolen; " <>
            "recovery is deliberate operator removal)"
        )

        :ok

      true ->
        Process.sleep(@drain_poll_ms)
        await_drain(deadline)
    end
  end

  defp in_flight_tasks do
    case Process.whereis(TaskSupervisor) do
      nil ->
        []

      supervisor ->
        supervisor
        |> DynamicSupervisor.which_children()
        |> Enum.map(&elem(&1, 1))
        |> Enum.reject(&(&1 == self()))
    end
  end

  # The socket node is the client's "daemon is gone" observable: unlink it
  # once the drain proves this daemon will serve nothing further. Only a
  # provably owned socket node is ever removed (the takeover's no-follow
  # proof); anything else at the path is left for the next boot's takeover
  # to judge, and an absent path is already the drained state.
  defp remove_socket! do
    path = Listener.socket_path()

    if Listener.owned_socket?(path) do
      case File.rm(path) do
        :ok ->
          :ok

        {:error, reason} ->
          # Best-effort: the next boot's takeover handles a lingering node
          # (connect-refused probe, then the same ownership proof). The stop
          # must not fail because the client-visible cleanup could not.
          Logger.warning("daemon stop: could not remove the socket node #{path}: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  defp drain_budget, do: Application.get_env(:daemon, :drain_timeout_ms, @drain_timeout_ms)

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
