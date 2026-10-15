defmodule Workstation.CLI.PreReplace do
  # Declared before the moduledoc so the doc can interpolate the real budget.
  @wait_ms 10_000
  @poll_ms 200

  @moduledoc """
  The lifecycle verbs' pre-replace daemon stop: before a verb that may
  replace the installed release (`apply`, `update`, `bootstrap`), a LIVE
  daemon is asked to exit gracefully and the client waits — bounded — for
  the daemon to actually go away.

  Why: the daemon runs the installed release in memory. A release
  replacement (the bootstrap step's refresh, or the checkout shim's
  acquisition) swaps the tree under the running beam, and a surviving
  daemon keeps serving stale code — the 2026-10-14 incident ended with an
  operator killing the beam by PID to unblock an apply. The graceful
  contract replaces that: the daemon's `daemon.stop` op drains in-flight
  ops (releasing their apply locks by letting the holders finish), removes
  the socket node, and halts (`Workstation.Daemon.Shutdown`); this module
  is the client half.

  Rules:

  * no live daemon (the no-spawn `DaemonClient.live?/1` probe) — nothing to
    stop, `:ok`; the verb's own first call spawns the fresh daemon
    on demand, from the current release;
  * the wait is bounded (`:wait_ms`, default #{@wait_ms |> div(1_000)}s) and
    polls TWO conditions: the socket node gone AND the daemon's beam OS
    process dead (the peer pid from `SO_PEERCRED` where the platform
    provides one, else the `daemon.stop` wire pid — see
    `DaemonClient.daemon_pid/2`; probed through the same `:cli, :beam_alive`
    seam as `Workstation.CLI.Control` — the daemon's own halt can wedge, and
    a socket-less-but-alive beam would make the next ensure-spawn die on
    `:already_running`); the production probe reads the `/proc/<pid>/stat`
    state on Linux and counts a zombie (`Z`) as EXITED — under a pid 1 that
    never reaps (containers, chroots) the defunct entry outlives the beam's
    death, and a bare `kill -0` existence probe reads it as alive;
  * on timeout or a refused stop, the verb FAILS CLOSED with an explicit
    error — this module never signals the process. Killing is the manual
    stop verb's escalation ladder (`Workstation.CLI.Control`), never the
    automated path's;
  * composing with the daemon-driven release-refresh handoff is free: the
    handoff's self-stop and this stop share the daemon's pending-stop
    marker, so a second request while a stop is pending is a daemon-side
    no-op and the wait simply observes the same shutdown.
  """

  alias Workstation.CLI.DaemonClient
  alias Workstation.Daemon.Listener

  @doc """
  Gracefully stop the live daemon serving `home` before a release
  replacement. Returns `:ok` once nothing is left serving (or when there
  was nothing to stop), `{:error, message}` when the stop was refused,
  unverifiable, or the daemon outlived the wait — the caller must refuse
  to replace the release.
  """
  @spec stop_daemon(keyword()) :: :ok | {:error, String.t()}
  def stop_daemon(opts \\ []) do
    home = Keyword.get(opts, :home) || Workstation.Core.EngineState.home()

    if live?(opts, home) do
      case stop_request(opts, home) do
        {:ok, _result, daemon_pid} when is_integer(daemon_pid) and daemon_pid > 0 ->
          await_exit(home, daemon_pid, opts, now_ms() + wait_ms(opts))

        {:ok, _result, nil} ->
          {:error, "could not identify the daemon process (peercred unavailable); refusing to replace the release"}

        {:error, message} ->
          {:error, "the running daemon refused the graceful stop (#{message}); refusing to replace the release under it"}
      end
    else
      :ok
    end
  end

  # Bounded poll for BOTH exit conditions. Socket gone without a dead beam
  # is NOT success: the drain removed the node before the halt, and a beam
  # wedged in its own exit would wedge the next ensure-spawn's bind.
  defp await_exit(home, daemon_pid, opts, deadline) do
    sock_path = Listener.socket_path(home)

    cond do
      socket_gone?(opts, sock_path) and not beam_alive?(daemon_pid) ->
        :ok

      now_ms() >= deadline ->
        {:error,
         "the daemon did not exit within #{div(wait_ms(opts), 1_000)}s of the graceful stop " <>
           "(socket #{if socket_gone?(opts, sock_path), do: "removed", else: "still present"}, " <>
           "beam pid #{daemon_pid} #{if beam_alive?(daemon_pid), do: "still alive", else: "exited"}); " <>
           "refusing to replace the release — inspect the daemon log under #{Path.dirname(sock_path)}"}

      true ->
        Process.sleep(@poll_ms)
        await_exit(home, daemon_pid, opts, deadline)
    end
  end

  ## seams (options are the test surface; the defaults are production)

  defp live?(opts, home) do
    case Keyword.get(opts, :live) do
      fun when is_function(fun, 1) -> fun.(home)
      _other -> DaemonClient.live?(home)
    end
  end

  # The stop request: the daemon.stop op on a control connection (never a
  # spawn). The seam (and the default) return `DaemonClient.control_with_pid`'s
  # exact shape — `{:ok, result, peer_pid | nil}` or `{:error, message}`. A
  # refusal (unknown op from a daemon too old to know daemon.stop, any other
  # protocol error) fails closed.
  defp stop_request(opts, home) do
    case Keyword.get(opts, :stop) do
      fun when is_function(fun, 1) ->
        fun.(home)

      _other ->
        DaemonClient.control_with_pid("daemon.stop", %{}, home: home)
    end
  end

  defp socket_gone?(opts, sock_path) do
    case Keyword.get(opts, :socket_gone?) do
      fun when is_function(fun, 1) -> fun.(sock_path)
      _other -> not File.exists?(sock_path)
    end
  end

  # Same probe seam as Workstation.CLI.Control: the production probe reads
  # the /proc state on Linux and falls back to `kill -0` elsewhere;
  # in-process test trees re-aim it (the test VM's OS pid IS the "daemon"
  # pid the peercred read captured).
  defp beam_alive?(pid) do
    case Application.get_env(:cli, :beam_alive) do
      fun when is_function(fun, 1) -> fun.(pid)
      _other -> process_alive?(pid)
    end
  end

  # The production probe. `kill -0` is existence-only, and a zombie EXISTS:
  # under a pid 1 that never reaps (`sleep infinity` in a container or
  # chroot — the 2026-10-15 bare-box rehearsal), the beam's defunct entry
  # outlives its death indefinitely, and the old probe read it as "still
  # alive", refusing every replace. On Linux the `/proc/<pid>/stat` state
  # character decides (`Z` is exited) and only an unreadable stat — no
  # /proc on macOS, hidepid, a pid that vanished mid-read — falls back to
  # `kill -0`.
  defp process_alive?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        case stat_alive?(stat) do
          nil -> kill_zero_alive?(pid)
          alive? -> alive?
        end

      {:error, _reason} ->
        kill_zero_alive?(pid)
    end
  end

  @doc """
  The `/proc/<pid>/stat` liveness verdict behind the production probe:
  `false` when the state character is `Z` — a zombie has exited and only
  awaits reap, so under a pid 1 that never reaps it is dead for every
  purpose this wait has — `true` for any other parseable state, `nil` when
  the stat text cannot be parsed (the caller falls back to the
  existence-only `kill -0` probe). Public because the zombie branch IS the
  contract this module carries: the bare-box rehearsal's false "still
  alive" was a defunct beam.
  """
  @spec stat_alive?(String.t()) :: boolean() | nil
  def stat_alive?(stat) do
    case proc_stat_state(stat) do
      nil -> nil
      "Z" -> false
      _state -> true
    end
  end

  # stat is `pid (comm) state ppid ...`; comm is free text that may itself
  # contain spaces and parentheses, so the state character sits after the
  # LAST `)` — none of the fields that follow contain one.
  defp proc_stat_state(stat) do
    case :binary.matches(stat, ")") do
      [] ->
        nil

      matches ->
        {pos, 1} = List.last(matches)
        rest = binary_part(stat, pos + 1, byte_size(stat) - pos - 1)

        case String.trim_leading(rest) do
          <<state, _tail::binary>> when state in ?A..?Z or state in ?a..?z -> <<state>>
          _other -> nil
        end
    end
  end

  defp kill_zero_alive?(pid) do
    {_, status} = System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    status == 0
  end

  defp wait_ms(opts), do: Keyword.get(opts, :wait_ms, @wait_ms)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
