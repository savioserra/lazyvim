defmodule Workstation.CLI.TUI.ExecutorTest do
  @moduledoc """
  The production executor seam: the daemon client (`Workstation.CLI.Daemon
  Client`) against a REAL in-process daemon tree — the same op surface the
  headless CLI drives. Payloads are validated before any wire traffic, a
  confirm carrying a generation the freshly built plan does not match is
  the honest stale refusal over the socket, and unknown steps are refused
  by the op schema, never dispatched. Serial: WORKSTATION_HOME and the
  daemon tree are process-global.
  """

  use ExUnit.Case, async: false

  alias Workstation.CLI.TUI.Executor
  alias Workstation.Daemon.Listener

  setup do
    home = Path.join(System.tmp_dir!(), "fusion-executor-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")
      File.rm_rf!(home)
    end)

    start_supervised!(Workstation.Daemon.Application.supervisor_spec())
    wait_for_file(Listener.socket_path())

    %{home: home}
  end

  test "malformed payloads are refused before the wire is touched" do
    assert {:error, "malformed apply request"} = Executor.apply_executor(%{})
    assert {:error, "malformed apply request"} = Executor.apply_executor(%{"generation" => "gen-1"})
    assert {:error, "malformed update request"} = Executor.update_executor(%{})
    assert {:error, "malformed update request"} = Executor.update_executor(%{"step" => 42})
  end

  test "a confirm for a generation the built plan does not match refuses stale over the wire" do
    # The sandbox home's freshly collected plan carries the checkout's real
    # (digest) generation; "gen-1" can never match it, so this pins the
    # confirm-exactly-what-you-saw contract at the seam. The refusal is the
    # daemon's apply_refused precondition: nothing is written to the home.
    assert {:error, message} = Executor.apply_executor(%{"generation" => "gen-1", "entries" => []})
    assert message =~ "apply_refused"
    assert message =~ "stale plan"
    assert message =~ "gen-1"
  end

  test "unknown lifecycle steps are refused by the op schema, never dispatched" do
    # The wire enum IS the contract now: an off-list step is invalid_params
    # at the protocol boundary (the in-process engine's unknown-step
    # message is unreachable from the client surface by construction).
    assert {:error, message} = Executor.update_executor(%{"step" => "reboot"})
    assert message =~ "invalid_params"
  end

  defp wait_for_file(path, tries \\ 100)

  defp wait_for_file(_path, 0), do: flunk("listener socket never appeared")

  defp wait_for_file(path, tries) do
    if File.exists?(path), do: :ok, else: (Process.sleep(20) && wait_for_file(path, tries - 1))
  end
end
