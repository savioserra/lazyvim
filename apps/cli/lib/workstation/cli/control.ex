defmodule Workstation.CLI.Control do
  @moduledoc """
  The `workstation daemon stop` client: the MANUAL stop path. Nothing in
  the engine stops a daemon behind the operator's back — a stop is always
  operator-initiated, either directly (this module, via the control frame)
  or indirectly (the daemon's own release-refresh handoff stop).

  The frame is one-way and unauthenticated by design: possession of the
  socket already implies the same uid (peercred authorizes every session),
  so an extra handshake would add ceremony, not security. The daemon's own
  halt is the FIRST step of the stop, never the whole story: a beam can
  stall in its own exit (flushing a wedged io server was the observed
  7m41s hang), so the stop verb CONFIRMS the beam process is gone before
  reporting success — see `confirm_exit/2`.
  """

  alias Workstation.CLI.DaemonClient
  alias Workstation.Core.ProcessState

  # The daemon's graceful stop drains in-flight ops (up to its
  # `:drain_timeout_ms`, default 30s) after the ~250ms reply flush, removes
  # the socket node, then halts — so the halt-confirmation budget covers the
  # drain plus ordinary exit jitter. SIGTERM then SIGKILL remain the
  # escalation for a WEDGED exit, never for a legitimate drain.
  @halt_confirm_ms 35_000
  @term_confirm_ms 3_000
  @kill_confirm_ms 2_000
  @poll_ms 100

  @doc """
  Ask the resident daemon to stop, then confirm the beam actually exits
  before reporting success. Returns `:ok` only once the daemon's OS process
  is confirmed dead, or `{:error, reason}` when no daemon could be reached,
  the beam never exited, or the daemon's process id could not be captured.
  """
  @spec stop() :: :ok | {:error, String.t()}
  def stop do
    # The op's wire result is %{{"stopping" => true, "pid" => <daemon os
    # pid>}} — the pid from the client's SO_PEERCRED read where the platform
    # provides one, else the daemon's own wire pid — a plain `:ok` arm can
    # never match and would crash the operator's stop with a
    # CaseClauseError exactly when it succeeded.
    case DaemonClient.control_with_pid("daemon.stop") do
      {:ok, %{"stopping" => true}, daemon_pid} when is_integer(daemon_pid) ->
        confirm_exit(daemon_pid)

      {:ok, _result, nil} ->
        {:error, "could not identify the daemon process (peercred unavailable)"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Wait — bounded — for the daemon's beam OS process to exit, escalating
  SIGTERM then SIGKILL: the acknowledged stop must never leave a zombie
  beam behind (the observed intermittent hang was a beam alive minutes
  after `daemon: stopped` was printed). Returns `:ok` on confirmed death,
  `{:error, reason}` if the process outlives every budget.

  Options (test budgets): `:halt_timeout_ms`, `:term_timeout_ms`,
  `:kill_timeout_ms`. The liveness probe is overridable with
  `Application.put_env(:cli, :beam_alive, fun/1)` for test trees whose
  "daemon" runs in-process (the real probe would see the test VM's own
  pid) — the shipped probe is the shared `/proc`-stat verdict
  (`Workstation.Core.ProcessState`: a zombie is exited — under a pid 1 that
  never reaps the daemon's defunct entry answers `kill -0` forever), falling
  back to `kill -0` only where the stat is unreadable.
  """
  @spec confirm_exit(pos_integer()) :: :ok | {:error, String.t()}
  def confirm_exit(daemon_pid, opts \\ []) when is_integer(daemon_pid) and daemon_pid > 0 do
    halt_budget = Keyword.get(opts, :halt_timeout_ms, @halt_confirm_ms)
    term_budget = Keyword.get(opts, :term_timeout_ms, @term_confirm_ms)
    kill_budget = Keyword.get(opts, :kill_timeout_ms, @kill_confirm_ms)

    if await_exit(daemon_pid, now_ms() + halt_budget) do
      :ok
    else
      # The daemon's own halt is wedged (a stalled flush was the observed
      # 7m41s hang); escalate — TERM first, KILL last, never unbounded.
      signal(daemon_pid, "-TERM")

      if await_exit(daemon_pid, now_ms() + term_budget) do
        :ok
      else
        signal(daemon_pid, "-KILL")

        if await_exit(daemon_pid, now_ms() + kill_budget) do
          :ok
        else
          {:error, "daemon beam (pid #{daemon_pid}) did not exit after SIGTERM and SIGKILL"}
        end
      end
    end
  end

  # Poll until the pid is gone (true) or the absolute deadline is spent
  # (false).
  defp await_exit(pid, deadline) do
    cond do
      not alive?(pid) ->
        true

      now_ms() >= deadline ->
        false

      true ->
        Process.sleep(@poll_ms)
        await_exit(pid, deadline)
    end
  end

  # The real probe is the shared liveness verdict
  # (`Workstation.Core.ProcessState`): the `/proc/<pid>/stat` state character
  # decides and a zombie is EXITED. A bare `kill -0` is existence-only, and
  # under a pid 1 that never reaps (the 2026-10-15 bare-box rehearsal) the
  # daemon's defunct entry answered it forever — this ladder burned SIGTERM +
  # SIGKILL and a 2s budget, then failed "did not exit after SIGTERM and
  # SIGKILL" over a beam that was already dead. `kill -0` decides only where
  # the stat is unreadable, and an inconclusive answer reads ALIVE: the
  # ladder keeps waiting and reports honestly rather than declaring a death
  # it could not see.
  defp process_alive?(pid), do: ProcessState.alive?(pid)

  defp alive?(pid) do
    case Application.get_env(:cli, :beam_alive) do
      fun when is_function(fun, 1) -> fun.(pid)
      _ -> process_alive?(pid)
    end
  end

  # Best-effort: a kill of an already-dead pid fails harmlessly and the
  # await that follows confirms the death.
  defp signal(pid, flag) do
    System.cmd("kill", [flag, Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
