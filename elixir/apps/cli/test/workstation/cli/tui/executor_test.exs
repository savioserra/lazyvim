defmodule Workstation.CLI.TUI.ExecutorTest do
  use ExUnit.Case, async: false

  # The production executor seam (b8 wiring): over a real daemon it must
  # surface the honest not_graduated refusal; without a daemon it must fail
  # closed. Serial: WORKSTATION_HOME is process-global and the daemon tree
  # binds a real unix socket per test home.
  alias Workstation.CLI.TUI.Executor
  alias Workstation.Daemon.Listener

  setup do
    home = Path.join(System.tmp_dir!(), "b8-executor-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")
      File.rm_rf!(home)
    end)

    %{home: home}
  end

  test "without a daemon the executors refuse instead of mutating locklessly" do
    assert {:error, :daemon_unavailable} =
             Executor.apply_executor(%{"generation" => "gen-1", "entries" => []})

    assert {:error, :daemon_unavailable} = Executor.update_executor(%{"step" => "pull"})

    # Malformed payloads never reach the socket path either.
    assert {:error, :daemon_unavailable} = Executor.apply_executor(%{})
    assert {:error, :daemon_unavailable} = Executor.update_executor(%{})
  end

  test "over a live daemon the executors surface the honest not_graduated gate" do
    start_supervised!(Workstation.Daemon.Application.supervisor_spec())
    wait_for_file(Listener.socket_path())

    assert {:error, {:daemon, "not_graduated", message}} =
             Executor.apply_executor(%{"generation" => "gen-1", "entries" => []})

    assert message =~ "no mutation path"

    assert {:error, {:daemon, "not_graduated", _}} = Executor.update_executor(%{"step" => "pull"})
  end

  test "daemon error codes stay binaries (no atom minting from the wire)" do
    start_supervised!(Workstation.Daemon.Application.supervisor_spec())
    wait_for_file(Listener.socket_path())

    # An unknown step is refused by the daemon's strict schema; the executor
    # hands the code through as a binary for the screen to render.
    assert {:error, {:daemon, "invalid_params", _}} = Executor.update_executor(%{"step" => "reboot"})
  end

  defp wait_for_file(path, tries \\ 100)

  defp wait_for_file(_path, 0), do: flunk("listener socket never appeared")

  defp wait_for_file(path, tries) do
    if File.exists?(path), do: :ok, else: (Process.sleep(20) && wait_for_file(path, tries - 1))
  end
end
