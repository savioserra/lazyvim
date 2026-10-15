defmodule Workstation.CLI.PreReplaceTest do
  @moduledoc """
  The lifecycle verbs' pre-replace daemon stop (`Workstation.CLI.PreReplace`):
  a live daemon is stopped gracefully and the client verifies BOTH exit
  conditions (socket node gone, beam dead) before reporting :ok; a timeout
  or a refused stop fails closed with an explicit error and never signals
  the process. The gates:

    * live daemon replaced without kill — a real test tree, the daemon-side
      graceful sequence running under the halt hook, and the beam-exit probe
      re-aimed (the in-process daemon's OS pid IS the test VM);
    * no daemon — a silent no-op that never spawns;
    * wedged daemon — the wait expires and the caller must refuse to
      replace the release;
    * refused stop (a daemon too old to know `daemon.stop`) — fail closed;
    * the production probe itself (no seam) — a reaped pid is exited, a
      genuinely live pid holds the wait, and the /proc stat verdict counts
      a zombie (`Z`) as exited: the bare-box rehearsal's false "still
      alive" (a pid 1 that never reaps leaves the defunct beam in /proc).
  """

  use ExUnit.Case, async: false

  alias Workstation.CLI.{PreReplace, Router}
  alias Workstation.Daemon.{Listener, Shutdown}

  # The client's spawn handshake budget (mirrors DaemonClient's).
  @spawn_wait_ms 10_000

  setup do
    home = Path.join(System.tmp_dir!(), "ws-pre-replace-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)

    no_repo = Path.join(home, "not-a-repo")
    File.mkdir_p!(no_repo)

    previous = %{
      "WORKSTATION_HOME" => System.get_env("WORKSTATION_HOME"),
      "WORKSTATION_ENGINE_REPO" => System.get_env("WORKSTATION_ENGINE_REPO")
    }

    System.put_env("WORKSTATION_HOME", home)
    System.put_env("WORKSTATION_ENGINE_REPO", no_repo)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      Application.delete_env(:daemon, :shutdown_hook)
      Application.delete_env(:cli, :beam_alive)
      Shutdown.reset()
      File.rm_rf!(home)
    end)

    %{home: home, socket_path: Listener.socket_path(home)}
  end

  test "a live daemon is stopped gracefully: acked, socket node gone, beam death verified", %{
    home: home,
    socket_path: socket_path
  } do
    # The production spawn shape: the daemon parks in its own process.
    parker = spawn(fn -> Router.main(["daemon"]) end)

    assert :ok = wait_for_socket(socket_path, now_ms() + @spawn_wait_ms),
           "the daemon verb did not bind #{socket_path} within the spawn handshake budget"

    # The daemon-side halt is hooked; the drain and the socket removal run
    # for real. The hook records that the socket node was ALREADY gone when
    # the halt step fired — the removal belongs to the graceful sequence,
    # not to the supervisor teardown.
    stopped = :atomics.new(1, signed: false)

    Application.put_env(:daemon, :shutdown_hook, fn _delay_ms, _reason ->
      :persistent_term.put({__MODULE__, :socket_at_halt}, File.exists?(socket_path))
      :atomics.put(stopped, 1, 1)
      spawn(fn -> Supervisor.stop(Workstation.Daemon.Supervisor) end)
    end)

    # The in-process daemon's OS pid IS this test VM, so "the beam is dead"
    # means "the stop hook has not fired yet" (the same re-aim the manual
    # stop verb's tests use).
    Application.put_env(:cli, :beam_alive, fn _pid -> :atomics.get(stopped, 1) == 0 end)

    try do
      assert :ok = PreReplace.stop_daemon(home: home)
      refute File.exists?(socket_path), "the daemon left its socket node behind"
      assert :persistent_term.get({__MODULE__, :socket_at_halt}, true) == false,
             "the socket node outlived the graceful sequence (the teardown removed it, not the stop)"
    after
      :persistent_term.erase({__MODULE__, :socket_at_halt})
      Application.delete_env(:daemon, :update_check)
      Process.exit(parker, :kill)
      _ = Shutdown.reset()
      wait_for(fn -> Process.whereis(Workstation.Daemon.Supervisor) == nil end, 5_000)
    end
  end

  test "no daemon: the gate is a silent no-op that never spawns", %{home: home, socket_path: socket_path} do
    assert :ok = PreReplace.stop_daemon(home: home)
    refute File.exists?(socket_path)
    assert Process.whereis(Workstation.Daemon.Supervisor) == nil
  end

  test "a wedged daemon fails the wait closed: the verb must refuse the replace", %{home: home} do
    stopped = :atomics.new(1, signed: false)

    Application.put_env(:cli, :beam_alive, fn _pid -> :atomics.get(stopped, 1) == 0 end)

    assert {:error, message} =
             PreReplace.stop_daemon(
               home: home,
               live: fn _home -> true end,
               stop: fn _home -> {:ok, %{"stopping" => true}, 4242} end,
               socket_gone?: fn _path -> false end,
               wait_ms: 50
             )

    assert message =~ "did not exit within"
    assert message =~ "refusing to replace the release"
    assert message =~ "4242"
  end

  test "a refused stop (a daemon predating daemon.stop) fails closed with the reason", %{home: home} do
    assert {:error, message} =
             PreReplace.stop_daemon(
               home: home,
               live: fn _home -> true end,
               stop: fn _home -> {:error, "unknown_op: op is not served by this daemon"} end
             )

    assert message =~ "unknown_op"
    assert message =~ "refusing to replace the release under it"
  end

  test "an unidentified daemon process (peercred unavailable) fails closed", %{home: home} do
    assert {:error, message} =
             PreReplace.stop_daemon(
               home: home,
               live: fn _home -> true end,
               stop: fn _home -> {:ok, %{"stopping" => true}, nil} end,
               socket_gone?: fn _path -> true end
             )

    assert message =~ "could not identify the daemon process"
  end

  test "the /proc stat verdict counts a zombie as exited (the bare-box defect: pid 1 never reaps)" do
    # The 2026-10-15 rehearsal's exact shape: the beam exited, the
    # container's `sleep infinity` pid 1 never reaped it, and the defunct
    # entry sat in /proc with ppid 1 — `ps aux` showed `[beam.smp]
    # <defunct>` while the old `kill -0` existence probe reported the
    # daemon alive and the replace was refused.
    zombie_stat =
      "3340 (beam.smp) Z 1 3290 3290 0 -1 4194560 0 0 0 0 0 0 0 0 20 0 1 0 " <>
        "883100938 905675264 18446744073709551615 1 1 0 0 0 0 0 16777216 " <>
        "134222336 32729 BEST_EFFORT 0 0 0 17 2 0 0 0 0 0 0 0 0 0 0 0 0 0 0"

    assert PreReplace.stat_alive?(zombie_stat) == false
  end

  test "the /proc stat verdict: live states are alive, the comm's own parens don't fool it, unparseable text defers" do
    for state <- ["R", "S", "D", "T", "t", "I"] do
      assert PreReplace.stat_alive?("3340 (beam.smp) #{state} 1 3290 3290 0 -1 4194560") == true,
             "state #{state} must read as alive"
    end

    # comm is free text: a comm carrying spaces and parentheses must not
    # shift the state field (the verdict reads past the LAST `)`).
    assert PreReplace.stat_alive?("12 (a) comm (with) parens ) S 0 1 1 0 -1") == true
    assert PreReplace.stat_alive?("3340 (weird (comm)) Z 1 1 1 0 -1") == false

    # Anything the parser cannot pin a state character on defers to the
    # caller's `kill -0` fallback.
    assert PreReplace.stat_alive?("not a stat line") == nil
    assert PreReplace.stat_alive?("3340 (beam.smp)   ") == nil
    assert PreReplace.stat_alive?("") == nil
  end

  test "the production probe (no seam): a reaped pid satisfies the exit wait", %{home: home} do
    # A real pid that WAS a process and is now reaped — the exit-status
    # message is the waitpid receipt — so /proc/<pid>/stat is gone and
    # `kill -0` answers ESRCH: the default probe must accept it as exited
    # on the first poll.
    port = Port.open({:spawn_executable, "/bin/sh"}, [:exit_status, args: ["-c", "sleep 0.2; exit 0"]])
    os_pid = elem(Port.info(port, :os_pid), 1)

    assert_receive {^port, {:exit_status, 0}}, 5_000
    if Port.info(port), do: Port.close(port)

    assert :ok =
             PreReplace.stop_daemon(
               home: home,
               live: fn _home -> true end,
               stop: fn _home -> {:ok, %{"stopping" => true}, os_pid} end,
               socket_gone?: fn _path -> true end
             )
  end

  test "the production probe (no seam): a genuinely live pid holds the wait to the deadline", %{home: home} do
    # The test VM itself is the live pid: the default probe must read it
    # alive through the real /proc stat (or `kill -0` off-Linux), so the
    # wait fails closed rather than reporting a phantom exit.
    assert {:error, message} =
             PreReplace.stop_daemon(
               home: home,
               live: fn _home -> true end,
               stop: fn _home -> {:ok, %{"stopping" => true}, List.to_integer(:os.getpid())} end,
               socket_gone?: fn _path -> true end,
               wait_ms: 50
             )

    assert message =~ "did not exit within"
    assert message =~ "still alive"
  end

  ## fixtures (the daemon-verb test's shapes, verbatim)

  defp wait_for_socket(path, deadline) do
    if File.exists?(path) do
      :ok
    else
      if now_ms() >= deadline do
        {:error, :timeout}
      else
        Process.sleep(50)
        wait_for_socket(path, deadline)
      end
    end
  end

  defp wait_for(_fun, budget) when budget <= 0, do: :ok

  defp wait_for(fun, budget) do
    if fun.() do
      :ok
    else
      Process.sleep(50)
      wait_for(fun, budget - 50)
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
