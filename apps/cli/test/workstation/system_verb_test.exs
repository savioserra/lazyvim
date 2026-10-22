defmodule Workstation.CLI.SystemVerbTest do
  @moduledoc """
  The `workstation system applied` verb contract: the nix switch drivers'
  receipt, end to end over the real socket. The dispatch reduces to one
  `system.applied` wire op on the caller's home's daemon; the daemon fans
  the event out on the `system` overlay domain
  (`Workstation.Daemon.Capabilities.System`) and the op result's message
  IS the operator-facing stdout.

  Parse shape pinned against the REAL Optimus spec: the two-element
  subcommand path (`[:system, :applied]`) and the strict positive-integer
  option parsers — `--generation 0` is a usage error at the parse
  boundary (exit 2), never a daemon round-trip. A daemon-less run fails
  fast with exit 4 (the client's ensure cannot spawn a release binary in
  a mix env — the refusal surface the driver sees on a broken host).
  """

  use ExUnit.Case, async: false

  alias Workstation.CLI.{Control, Router}
  alias Workstation.Daemon.{Boot, Listener, Shutdown}

  # Fixture homes are cross-VM collision-proof (see the full note in
  # apps/daemon/test/workstation/daemon/generation_test.exs).
  defp unique_home(prefix) do
    token = Integer.to_string(:os.system_time(:millisecond), 36)
    home = Path.join(System.tmp_dir!(), "#{prefix}-#{token}")

    File.rm_rf!(home)
    on_exit(fn -> File.rm_rf!(home) end)
    home
  end

  setup do
    home = unique_home("ws-system-verb")
    File.mkdir_p!(home)

    previous = %{
      "WORKSTATION_HOME" => System.get_env("WORKSTATION_HOME"),
      "WORKSTATION_ENGINE_REPO" => System.get_env("WORKSTATION_ENGINE_REPO")
    }

    # Hermetic update check: pin the engine repo at a non-repository (the
    # check answers the disabled "unknown" without any git execution).
    no_repo = Path.join(home, "not-a-repo")
    File.mkdir_p!(no_repo)
    System.put_env("WORKSTATION_HOME", home)
    System.put_env("WORKSTATION_ENGINE_REPO", no_repo)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    %{home: home}
  end

  test "system applied publishes over the wire and prints the receipt", %{home: home} do
    parker = spawn(fn -> Router.main(["daemon"]) end)
    socket_path = Listener.socket_path(home)
    wait_for_socket(socket_path, now_ms() + 10_000)

    sup_pid = Process.whereis(Workstation.Daemon.Supervisor)

    Elixir.Application.put_env(:daemon, :shutdown_hook, fn _delay_ms, _reason ->
      spawn(fn -> Supervisor.stop(sup_pid) end)
    end)

    try do
      {result, stdout, stderr} =
        run_main_capturing_output([
          "system",
          "applied",
          "--generation",
          "7",
          "--rollback-generation",
          "6"
        ])

      assert :ok = result
      assert stdout =~ "generation 7 applied (rollback available at 6)"
      assert stderr == ""

      {result, stdout, _stderr} = run_main_capturing_output(["system", "applied", "--generation", "1"])

      assert :ok = result
      assert stdout =~ "generation 1 applied (no prior generation)"
    after
      Elixir.Application.delete_env(:daemon, :shutdown_hook)
      Process.exit(parker, :kill)
      _ = Shutdown.reset()
      File.rm(socket_path)
      wait_for(fn -> Process.whereis(Workstation.Daemon.Supervisor) == nil end, 5_000)
    end
  end

  test "system applied with NO daemon fails fast (exit 4) and never spawns in a mix env", %{
    home: home
  } do
    {result, _stdout, stderr} = run_main_capturing_output(["system", "applied", "--generation", "2"])

    assert {:shutdown, 4} = result
    assert stderr =~ "error:"

    # The publish verb must never stand a tree up in a test VM (the
    # ensure path cannot spawn a release binary here) — no socket, no tree.
    Process.sleep(200)
    refute File.exists?(Listener.socket_path(home))
    refute Process.whereis(Workstation.Daemon.Supervisor)
  end

  test "the parse shape: two-element path, parsed positive integers, flattened options" do
    assert {:ok, [:system, :applied], result} =
             Optimus.parse(Router.parser(), [
               "system",
               "applied",
               "--generation",
               "7",
               "--rollback-generation",
               "6"
             ])

    assert result.options[:generation] == 7
    assert result.options[:rollback_generation] == 6

    assert {:ok, [:system, :applied], bare} =
             Optimus.parse(Router.parser(), ["system", "applied", "--generation", "3"])

    assert bare.options[:generation] == 3
    assert bare.options[:rollback_generation] == nil
  end

  test "non-positive and non-integer generations are usage errors at the parse boundary" do
    for bad <- ["0", "-1", "x", "3.5", ""] do
      # Subcommand-path parse errors carry the path: {:error, path, errors}.
      assert {:error, _, errors} =
               Optimus.parse(Router.parser(), ["system", "applied", "--generation", bad]),
             "expected #{inspect(bad)} to be refused"

      assert Enum.join(errors, "; ") =~ "expected a positive integer"
    end

    # --rollback-generation carries the same strictness.
    assert {:error, _, _errors} =
             Optimus.parse(Router.parser(), ["system", "applied", "--generation", "7", "--rollback-generation", "0"])
  end

  test "--generation is required (usage error, never a daemon round-trip)" do
    assert {:error, _, errors} = Optimus.parse(Router.parser(), ["system", "applied"])
    assert Enum.join(errors, "; ") =~ "missing required options: --generation"
  end

  test "the verb stays OUT of the release control-script verb list" do
    # ControlVerbs.list() forwards verbs to bin/workstation_ctl; `system`
    # must route to the Router (its dispatch is the only speakable form).
    refute "system" in Workstation.CLI.ControlVerbs.list()
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
  # streams (the daemon_verb_test's shape).
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

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp wait_for(fun, remaining) do
    cond do
      fun.() -> :ok
      remaining <= 0 -> flunk("condition never became true")
      true -> (Process.sleep(20) && wait_for(fun, remaining - 20))
    end
  end
end
