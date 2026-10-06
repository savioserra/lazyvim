defmodule Workstation.CLI.DaemonVerbTest do
  @moduledoc """
  The `workstation daemon` verb contract at the Router: the BARE verb is
  the foreground boot the ensure-daemon spawn targets — the daemon state
  socket must bind and answer a versioned handshake within the client's
  spawn handshake budget (`Workstation.CLI.DaemonClient`'s spawn wait,
  10s) — a second boot on the same VM refuses fast with exit 4, and
  `daemon stop` is the manual stop path.

  Regression for the 2026-10-06 hang: the release dispatcher intercepted
  `daemon` to the OTP control script, so the spawned VM never reached this
  dispatch — it idled detached with no socket and every ensure-spawn timed
  out with an empty daemon.log. This module pins the Router-level contract
  that interception broke (the shipped-dispatcher verb list is pinned by
  `Workstation.CLI.ControlVerbsTest`).
  """

  use ExUnit.Case, async: false

  alias Workstation.CLI.{Control, DaemonClient, Router}
  alias Workstation.Daemon.{Listener, Shutdown}

  # The client's spawn handshake budget: a daemon that binds later than
  # this makes every ensure-spawn fail with daemon_unavailable.
  @spawn_wait_ms 10_000

  setup do
    home = Path.join(System.tmp_dir!(), "ws-daemon-verb-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)

    # Hermetic update check: Boot.run opts the resident daemon in, so pin
    # the engine repo at a non-repository (the check answers the disabled
    # "unknown" without any git execution — never the real checkout).
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

      File.rm_rf!(home)
    end)

    %{home: home}
  end

  test "the bare daemon verb boots, serves the spawn-budget handshake, refuses a second boot, and stops", %{
    home: home
  } do
    # The production spawn shape: Router.main(["daemon"]) in its own
    # process — Boot.run starts the tree and parks that process forever.
    parker = spawn(fn -> Router.main(["daemon"]) end)

    socket_path = Listener.socket_path(home)

    assert :ok = wait_for_socket(socket_path, now_ms() + @spawn_wait_ms),
           "the daemon verb did not bind #{socket_path} within the " <>
             "#{@spawn_wait_ms}ms ensure-spawn handshake budget"

    # The handshake is the liveness signal: the same versioned hello the
    # client's spawn wait re-tries must answer here.
    assert {:ok, %{"schema" => "workstation.status.v1"}} =
             DaemonClient.call("status.run", %{}, home: home, timeout_ms: 5_000)

    # A second foreground boot must refuse LOUD (exit 4) — never hang and
    # never boot a second tree on the same home.
    {result, stderr} = run_main_capturing_stderr(["daemon"])

    assert {:shutdown, 4} = result
    assert stderr =~ "a daemon is already running at #{socket_path}"

    # The manual stop path through the live socket, with the daemon's
    # delayed self-stop hooked (the real path halts the VM — a
    # supervisor-spec test tree must not), then the parker is killed and
    # the tree torn down.
    Elixir.Application.put_env(:daemon, :shutdown_hook, fn _delay_ms, _reason ->
      spawn(fn -> Supervisor.stop(Workstation.Daemon.Supervisor) end)
    end)

    try do
      assert :ok = Control.stop()
    after
      # Boot.run opts the resident daemon into the update check (VM-global
      # application env) — a supervisor-spec tree elsewhere must stay opted
      # OUT, so undo the opt-in with the shutdown hook.
      Elixir.Application.delete_env(:daemon, :update_check)
      Elixir.Application.delete_env(:daemon, :shutdown_hook)
      Process.exit(parker, :kill)
      _ = Shutdown.reset()
      File.rm(socket_path)
      # The tree shuts down asynchronously (the parker kill cascades); the
      # global Workstation.Daemon.Supervisor name must be free before this
      # test ends.
      wait_for(fn -> Process.whereis(Workstation.Daemon.Supervisor) == nil end, 5_000)
    end
  end

  ## plumbing

  defp wait_for_socket(path, deadline) when is_integer(deadline) do
    cond do
      File.exists?(path) -> :ok
      now_ms() >= deadline -> flunk("state socket never appeared at #{path}")
      true -> (Process.sleep(20) && wait_for_socket(path, deadline))
    end
  end

  defp run_main_capturing_stderr(argv) do
    me = self()

    {pid, ref} =
      spawn_monitor(fn ->
        stderr =
          ExUnit.CaptureIO.capture_io(:stderr, fn ->
            result =
              try do
                Router.main(argv)
                :ok
              catch
                :exit, {:shutdown, code} -> {:shutdown, code}
              end

            send(me, {:main_result, result})
          end)

        send(me, {:main_stderr, stderr})
      end)

    result =
      receive do
        {:main_result, result} -> result
        {:DOWN, ^ref, :process, ^pid, reason} -> {:down, reason}
      after
        30_000 -> flunk("router main did not finish")
      end

    stderr =
      receive do
        {:main_stderr, stderr} -> stderr
      after
        5_000 -> ""
      end

    {result, stderr}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp wait_for(fun, remaining) do
    cond do
      fun.() -> :ok
      remaining <= 0 -> flunk("condition never became true")
      true -> (Process.sleep(20) && wait_for(fun, remaining - 20))
    end
  end
end
