defmodule Workstation.CLI.ControlTest do
  @moduledoc """
  The stop verb's verify-then-report ladder (`Control.confirm_exit/2`):
  the daemon's acknowledged stop must be CONFIRMED — the beam exits within
  the halt budget, else SIGTERM, else SIGKILL, else the verb fails loudly
  instead of printing `daemon: stopped` over a live beam (the intermittent
  7m41s hang). The ladder is pinned end to end with real OS signals against
  real child processes (`/bin/sh` ports): an obedient exit, a SIGTERM-trapping
  holdout that only KILL moves, and a never-dying process (the liveness probe
  is overridden) that must surface as an error, never a success.
  """

  use ExUnit.Case, async: false

  alias Workstation.CLI.Control

  setup do
    previous = Application.get_env(:cli, :beam_alive)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:cli, :beam_alive, previous),
        else: Application.delete_env(:cli, :beam_alive)
    end)

    :ok
  end

  test "reports :ok once the process exits on its own — no escalation needed" do
    {port, pid} = spawn_os_process(["-c", "sleep 0.2"])

    try do
      assert :ok = Control.confirm_exit(pid, halt_timeout_ms: 3_000)
      refute process_alive?(pid), "pid #{pid} should be gone"
    after
      reap(port, pid)
    end
  end

  test "escalates SIGKILL when SIGTERM is trapped" do
    {port, pid} = spawn_os_process(["-c", "trap '' TERM; sleep 30"])

    try do
      assert :ok =
               Control.confirm_exit(pid,
                 halt_timeout_ms: 200,
                 term_timeout_ms: 300,
                 kill_timeout_ms: 3_000
               )

      refute process_alive?(pid), "pid #{pid} ignored SIGTERM and survived SIGKILL"
    after
      reap(port, pid)
    end
  end

  test "fails loudly when the beam never exits — never a false stopped" do
    Application.put_env(:cli, :beam_alive, fn _pid -> true end)
    {port, pid} = spawn_os_process(["-c", "sleep 30"])

    try do
      assert {:error, message} =
               Control.confirm_exit(pid,
                 halt_timeout_ms: 150,
                 term_timeout_ms: 150,
                 kill_timeout_ms: 150
               )

      assert message =~ "did not exit after SIGTERM and SIGKILL"
      assert message =~ to_string(pid)
    after
      reap(port, pid)
    end
  end

  test "the pid guard is strict: a non-positive pid is a caller bug" do
    assert_raise FunctionClauseError, fn -> Control.confirm_exit(0) end
  end

  defp spawn_os_process(sh_args) do
    port = Port.open({:spawn_executable, "/bin/sh"}, [:exit_status, args: sh_args])
    assert {:os_pid, os_pid} = :erlang.port_info(port, :os_pid)
    {port, os_pid}
  end

  defp process_alive?(pid) do
    {_, status} = System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    status == 0
  end

  # A port closes ITSELF when its process exits, delivering
  # {port, {:exit_status, status}} to its owner, so the reap waits for that
  # message and only closes the port if it somehow never arrives.
  defp reap(port, pid) do
    _ = System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      2_000 -> Port.close(port)
    end

    :ok
  end
end
