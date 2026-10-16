defmodule Workstation.Daemon.Shutdown do
  # Declared before the moduledoc so the doc can interpolate the real budgets.
  @reply_flush_ms 250
  @flush_wait_ms 5_000
  @flush_poll_ms 10
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

  The teardown must never race the stop-granting op's reply off the wire:
  the supervisor kills the session BEFORE the listener (children shut down
  in reverse start order), so a teardown that starts too early kills the
  reply mid-flight and the operator's stop reports a daemon death on a
  stop that was granted — the `{:shutdown, 4}` / `daemon_died` flake. Two
  mechanisms pin the ordering — a timing floor plus a deterministic ack:

    * the DELAY — the stop process first sleeps the flush window (default
      #{@reply_flush_ms} ms, `Application` env `:daemon, :reply_flush_ms`),
      the floor the handshake has always had;
    * the FLUSH ACK — the deterministic half. `stop_after/2` carries the
      scheduling op's wire `op_ref`, and the session calls `reply_flushed/1`
      with it the moment the op's reply frame has actually been handed to
      the socket. The stop process waits — bounded (`:daemon,
      :flush_wait_ms`, default #{@flush_wait_ms |> div(1_000)}s, polled
      every #{@flush_poll_ms}ms) — for that ack before anything else. The
      ack is armed only for the stop's own op_ref, so every other reply's
      ack is a no-op. A stop whose client vanished mid-op never acks and
      times out through the budget — the stop is never unbounded, and a
      vanished reader is nobody waiting for the reply.

  The sequence after the handshake is the graceful contract the lifecycle
  verbs depend on:

    1. DRAIN — wait, bounded (`:drain_timeout_ms`, default
       #{@drain_timeout_ms |> div(1_000)}s), for every in-flight op task
       under `Workstation.Daemon.TaskSupervisor` to settle. The flush ack
       already proves the scheduling task done (the session answered it),
       so the drain waits for genuinely OTHER ops only. A settling op
       releases its own apply lock (`Workstation.Core.ApplyLock` — the
       holder removes the file itself inside the op's lock scope), so a
       drained stop never leaves the "apply lock not released cleanly"
       debris a kill leaves. A drain that outlives its budget logs and
       proceeds — the stop is never unbounded, and a lock left behind by an
       interrupted op is fail-closed recovery: a holder provably dead on
       this host is taken over (with an audit record) on the next run, a
       live or pid-less lock still requires deliberate operator removal.
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
  Schedule a graceful daemon stop, `reason`-annotated, to fire after the
  flush handshake (the delay floor plus, when the caller was a wire op
  carrying `op_ref`, the deterministic reply-flush ack). Idempotent while a
  stop is pending.
  """
  @spec stop_after(String.t()) :: :ok
  def stop_after(reason) when is_binary(reason) do
    schedule(reply_flush_ms(), reason, nil)
  end

  @doc """
  Like `stop_after/1` for a WIRE op: `op_ref` is the scheduling op's stream
  token, which the session acks through `reply_flushed/1` once the op's
  reply frame is on the socket — the stop proceeds past the handshake only
  then (bounded by the flush budget when the client vanished mid-op). A nil
  ref — an in-process caller with no session to flush a reply — keeps the
  plain delay-floor contract.
  """
  @spec stop_after(String.t(), String.t() | nil) :: :ok
  def stop_after(reason, op_ref) when is_binary(reason) do
    schedule(reply_flush_ms(), reason, op_ref)
  end

  # The stop process (spawned, unlinked — the stopping daemon must not die
  # WITH its caller's session; it outlives the op by the handshake plus the
  # drain) runs the SAME sequence on both paths: the test seam replaces the
  # HALT itself, never the bookkeeping or the ordering. A supervisor-spec
  # test tree cannot let the real System.halt/1 kill the mix run, but the
  # handshake, the pending-stop idempotency, the drain and the socket
  # removal must hold identically (Workstation.Daemon.Shutdown.reset/0
  # clears the markers between tests).
  defp schedule(delay_ms, reason, op_ref) do
    if :persistent_term.get({__MODULE__, :stopping}, false) do
      :ok
    else
      :persistent_term.put({__MODULE__, :stopping}, true)

      # Pin the sequence to THIS generation: the socket path and the task
      # supervisor are resolved HERE — while the scheduling daemon is
      # definitely the ambient one — and the stop process carries the values.
      # Resolving them at execution time instead let a late stop process
      # (it outlives the scheduling op by the flush handshake plus the
      # drain) drain a LATER tree's op tasks and unlink a LATER home's
      # socket node — in a test VM the ambient home and the registered
      # names belong to whichever generation is current when the budget
      # expires, not to the generation that scheduled the stop.
      sock_path = Listener.socket_path()
      task_sup = Process.whereis(TaskSupervisor)

      ack = :atomics.new(1, signed: false)

      # Armed BEFORE the spawn: a fast reply can ack before the stop
      # process is ever scheduled, and the ack must not be lost (atomics
      # are state, not messages — the late reader still sees it).
      if is_binary(op_ref) do
        :persistent_term.put({__MODULE__, :flush_ack}, {op_ref, ack})
      end

      case Application.get_env(:daemon, :shutdown_hook) do
        hook when is_function(hook, 2) ->
          spawn(fn ->
            Process.sleep(delay_ms)
            await_reply_flushed(op_ref, ack)
            drain_ops!(task_sup)
            remove_socket!(sock_path)
            hook.(delay_ms, reason)
          end)

        _real ->
          spawn(fn ->
            Process.sleep(delay_ms)
            await_reply_flushed(op_ref, ack)
            drain_ops!(task_sup)
            remove_socket!(sock_path)
            Logger.info("workstation daemon stopping: #{reason}")
            _ = Application.stop(:daemon)
            System.halt(0)
          end)
      end

      :ok
    end
  end

  @doc """
  The SESSION half of the flush handshake: the reply frame for `op_ref` has
  been handed to the socket, so a graceful stop scheduled by that op may
  proceed past the handshake. Matches only the pending stop's own op_ref —
  every other reply's ack is a no-op.
  """
  @spec reply_flushed(String.t()) :: :ok
  def reply_flushed(op_ref) when is_binary(op_ref) do
    case :persistent_term.get({__MODULE__, :flush_ack}, :none) do
      {^op_ref, ack} -> :atomics.put(ack, 1, 1)
      _other -> :ok
    end

    :ok
  end

  @doc "Whether a stop has already been scheduled (diagnostics)."
  @spec stopping?() :: boolean()
  def stopping?, do: :persistent_term.get({__MODULE__, :stopping}, false)

  @doc "Clear the pending-stop markers (tests; the real daemon never resets)."
  @spec reset() :: :ok
  def reset do
    :persistent_term.put({__MODULE__, :stopping}, false)
    :persistent_term.erase({__MODULE__, :flush_ack})
    :ok
  end

  ## flush handshake ---------------------------------------------------------

  # The deterministic half: wait for the session's ack (the reply frame was
  # handed to the socket) before any teardown. With no wire op_ref — an
  # in-process caller has no session to flush a reply — the wait is skipped
  # and the delay floor alone orders the stop, exactly the pre-ack contract.
  # Bounded: a client that vanished mid-op never acks, and the stop must
  # never hang on it.
  defp await_reply_flushed(op_ref, _ack) when not is_binary(op_ref), do: :ok

  defp await_reply_flushed(_op_ref, ack) do
    budget = flush_wait_ms()
    await_reply_flushed(ack, monotonic_ms() + budget, budget)
  end

  defp await_reply_flushed(ack, deadline, budget) do
    cond do
      :atomics.get(ack, 1) == 1 ->
        :ok

      monotonic_ms() >= deadline ->
        Logger.warning(
          "daemon stop: no reply-flush ack within #{budget}ms (the client may have vanished mid-op); " <>
            "proceeding with the graceful stop"
        )

        :ok

      true ->
        Process.sleep(@flush_poll_ms)
        await_reply_flushed(ack, deadline, budget)
    end
  end

  ## graceful sequence -------------------------------------------------------

  # Bounded wait for every in-flight op task to settle. The flush ack
  # already proves the scheduling task done — the session answered its
  # reply, which happens only after the task sent the session its result —
  # so this waits for genuinely OTHER ops: a settling op releases its own
  # apply lock, and the stop never un-bounds. A supervisor-less context
  # (CLI one-shot, plain unit tests) has no tasks to wait for at all.
  # `task_sup` is the scheduling generation's supervisor, captured at
  # schedule time: a dead pid means the generation rolled and its ops died
  # with it — nothing of ours is in flight, so the drain is already done.
  defp drain_ops!(task_sup) do
    deadline = monotonic_ms() + drain_budget()

    case in_flight_tasks(task_sup) do
      [] ->
        :ok

      tasks ->
        Logger.info("daemon stop: draining #{length(tasks)} in-flight op task(s)")
        await_drain(task_sup, deadline)
    end
  end

  defp await_drain(task_sup, deadline) do
    cond do
      in_flight_tasks(task_sup) == [] ->
        :ok

      # Not a fresh liveness check — the budget bounds the WHOLE drain, so a
      # trickle of new tasks cannot extend it past the stop.
      monotonic_ms() >= deadline ->
        Logger.warning(
          "daemon stop: drain budget spent with op task(s) still in flight; stopping anyway — " <>
            "an interrupted op may leave its apply lock in place (a holder provably dead on " <>
            "this host is taken over with an audit record on the next run; a live or " <>
            "pid-less lock still requires deliberate operator removal)"
        )

        :ok

      true ->
        Process.sleep(@drain_poll_ms)
        await_drain(task_sup, deadline)
    end
  end

  defp in_flight_tasks(task_sup) do
    if is_pid(task_sup) and Process.alive?(task_sup) do
      task_sup
      |> DynamicSupervisor.which_children()
      |> Enum.map(&elem(&1, 1))
    else
      []
    end
  end

  # The socket node is the client's "daemon is gone" observable: unlink it
  # once the drain proves this daemon will serve nothing further. Only a
  # provably owned socket node is ever removed (the takeover's no-follow
  # proof); anything else at the path is left for the next boot's takeover
  # to judge, and an absent path is already the drained state. `path` is
  # THIS generation's socket path, captured at schedule time — the ambient
  # home by the time a late stop process executes may already belong to a
  # different generation, and this stop must never touch it.
  defp remove_socket!(path) do
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

  defp reply_flush_ms, do: Application.get_env(:daemon, :reply_flush_ms, @reply_flush_ms)
  defp flush_wait_ms, do: Application.get_env(:daemon, :flush_wait_ms, @flush_wait_ms)
  defp drain_budget, do: Application.get_env(:daemon, :drain_timeout_ms, @drain_timeout_ms)

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
