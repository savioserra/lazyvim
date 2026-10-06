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
  out with an empty daemon.log. Regression for the daemon-stop INVERSION
  exposed by that fix (latent since the nested read landed): the dispatch
  read `result.args[:daemon][:action]`, but Optimus FLATTENS the matched
  subcommand's positionals (`["daemon", "stop"]` parses to
  `%{action: "stop"}`), so `daemon stop` always fell into the boot arm —
  with a live daemon it died on the supervisor EXIT instead of stopping,
  with none it booted a resident daemon. Both are pinned here.

  This module pins the Router-level contract that interception broke (the
  shipped-dispatcher verb list is pinned by
  `Workstation.CLI.ControlVerbsTest`).
  """

  use ExUnit.Case, async: false

  alias Workstation.CLI.{Control, DaemonClient, Router}
  alias Workstation.Daemon.{Boot, Listener, Shutdown}

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
    {result, _stdout, stderr} = run_main_capturing_output(["daemon"])

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

  test "the daemon action parses FLATTENED: stop is %{action: \"stop\"}, bare is %{action: nil}",
       _context do
    # Pin the real Optimus parse shape (the public Router.parser spec, not a
    # copy): the daemon dispatch reads result.args[:action] because Optimus
    # flattens the matched subcommand's positionals — the nested
    # result.args[:daemon][:action] read was ALWAYS nil.
    assert {:ok, [:daemon], result} = Optimus.parse(Router.parser(), ["daemon", "stop"])
    assert result.args == %{action: "stop"}

    assert {:ok, [:daemon], bare} = Optimus.parse(Router.parser(), ["daemon"])
    assert bare.args == %{action: nil}
  end

  test "daemon stop with a live daemon stops it: acked rc 0, socket unserved, daemon gone",
       %{home: home} do
    # The production spawn shape: the daemon parks in its own process.
    parker = spawn(fn -> Router.main(["daemon"]) end)
    socket_path = Listener.socket_path(home)

    assert :ok = wait_for_socket(socket_path, now_ms() + @spawn_wait_ms),
           "the daemon verb did not bind #{socket_path} within the " <>
             "#{@spawn_wait_ms}ms ensure-spawn handshake budget"

    # The real stop halts the VM; a supervisor-spec test tree must not —
    # hook the halt to a supervisor stop (identical teardown, no halt).
    Elixir.Application.put_env(:daemon, :shutdown_hook, fn _delay_ms, _reason ->
      spawn(fn -> Supervisor.stop(Workstation.Daemon.Supervisor) end)
    end)

    try do
      {result, stdout, _stderr} = run_main_capturing_output(["daemon", "stop"])

      # Returning (instead of exiting a tuple) IS the rc-0 contract; the
      # daemon acknowledged the stop with the operator-facing line.
      assert :ok = result
      assert stdout =~ "daemon: stopped"

      # The daemon is gone: the tree is down and nothing answers the socket
      # any more (a stop leaves the dead socket NODE on disk by design — the
      # next boot's takeover probes it dead and unlinks it).
      wait_for(fn -> Process.whereis(Workstation.Daemon.Supervisor) == nil end, 5_000)
      assert {:error, "no daemon is running for home " <> _} = Control.stop()
    after
      Elixir.Application.delete_env(:daemon, :update_check)
      Elixir.Application.delete_env(:daemon, :shutdown_hook)
      Process.exit(parker, :kill)
      _ = Shutdown.reset()
      File.rm(socket_path)
      wait_for(fn -> Process.whereis(Workstation.Daemon.Supervisor) == nil end, 5_000)
    end
  end

  test "daemon stop with NO daemon fails fast (exit 4) and never boots", %{home: home} do
    socket_path = Listener.socket_path(home)

    {result, _stdout, stderr} = run_main_capturing_output(["daemon", "stop"])

    assert {:shutdown, 4} = result
    assert stderr =~ "error: daemon stop failed"
    assert stderr =~ "no daemon is running for home #{home}"

    # The pre-fix inversion BOOTED a resident daemon and parked here (the
    # helper's 30s watchdog would flunk): nothing must ever bind the socket.
    Process.sleep(200)
    refute File.exists?(socket_path)
    refute Process.whereis(Workstation.Daemon.Supervisor)
  end

  test "a failed tree start returns the child's reason instead of EXITing the caller",
       %{home: home} do
    # The daemon dir is a dangling symlink: the Listener child cannot create
    # its directory, so the tree start fails INSIDE the child — the pre-fix
    # shape killed the caller with a raw supervisor EXIT before any error
    # arm could match.
    File.mkdir_p!(Path.join(home, ".local/state/workstation"))
    File.ln_s!(Path.join(home, "missing"), Path.join(home, ".local/state/workstation/daemon"))

    try do
      assert {:error, {:daemon_dir_create_failed, :eexist}} = Boot.run()

      {result, _stdout, stderr} = run_main_capturing_output(["daemon"])
      assert {:shutdown, 4} = result
      assert stderr =~ "error: daemon boot failed"
    after
      # Boot.run opts the (never-started) daemon into the update check —
      # undo the VM-global env for the other tests.
      Elixir.Application.delete_env(:daemon, :update_check)
    end
  end

  test "a live peer owning the socket refuses the boot with {:error, {:already_running, path}}",
       %{home: home} do
    # The cross-boot refusal (the operator's daemon runs in another VM):
    # a live endpoint on the socket path must make the Listener child's
    # takeover probe report :already_running — surfaced here as the error
    # TUPLE Boot.run documents, never a raw EXIT.
    socket_path = Listener.socket_path(home)
    File.mkdir_p!(Path.dirname(socket_path))

    {:ok, peer_sock} = :socket.open(:local, :stream, :default)
    :ok = :socket.bind(peer_sock, %{family: :local, path: String.to_charlist(socket_path)})
    :ok = :socket.listen(peer_sock)
    peer = spawn(fn -> fake_peer_loop(peer_sock) end)

    try do
      assert {:error, {:already_running, ^socket_path}} = Boot.run()
    after
      Process.exit(peer, :kill)
      _ = :socket.close(peer_sock)
      File.rm(socket_path)
      Elixir.Application.delete_env(:daemon, :update_check)
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

  # Runs Router.main(argv) in its own process and captures both output
  # streams: stdout via the group leader (per-process), stderr via the
  # global :standard_error device. Returns {result, stdout, stderr} where
  # result is :ok (main returned), {:shutdown, code} (main exited) or
  # {:down, reason} (the process crashed — the pre-fix raw supervisor EXIT
  # surfaces here).
  defp run_main_capturing_output(argv) do
    me = self()

    {pid, ref} =
      spawn_monitor(fn ->
        stderr =
          ExUnit.CaptureIO.capture_io(:stderr, fn ->
            stdout =
              ExUnit.CaptureIO.capture_io(fn ->
                result =
                  try do
                    Router.main(argv)
                    :ok
                  catch
                    :exit, {:shutdown, code} -> {:shutdown, code}
                  end

                send(me, {:main_result, result})
              end)

            send(me, {:main_stdout, stdout})
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

    stdout =
      receive do
        {:main_stdout, stdout} -> stdout
      after
        5_000 -> ""
      end

    stderr =
      receive do
        {:main_stderr, stderr} -> stderr
      after
        5_000 -> ""
      end

    {result, stdout, stderr}
  end

  # Minimal stand-in for a foreign daemon on the socket path: accept the
  # takeover probe's connection and answer it with one byte — any reply
  # proves a live generation owns the endpoint.
  defp fake_peer_loop(sock) do
    case :socket.accept(sock) do
      {:ok, conn} ->
        _ = :socket.recv(conn, 1, 2_000)
        _ = :socket.send(conn, "x")
        Process.sleep(1_000)
        fake_peer_loop(sock)

      {:error, _reason} ->
        :ok
    end
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
