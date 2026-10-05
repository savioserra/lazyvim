defmodule Workstation.CLI.TUI.ExecutorTest do
  use ExUnit.Case, async: false

  # The production executor seam (fusion wiring): the one-shot in-process
  # engine (`Workstation.CLI.Engine`) under the target home's apply lock.
  # Payloads are validated before the engine is touched, and a confirm
  # carrying a generation the freshly built plan does not match is the
  # honest stale refusal — never a silent apply of something else.
  # Serial: WORKSTATION_HOME is process-global.
  alias Workstation.CLI.TUI.Executor

  setup do
    home = Path.join(System.tmp_dir!(), "fusion-executor-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")
      File.rm_rf!(home)
    end)

    %{home: home}
  end

  test "malformed payloads are refused before the engine runs" do
    assert {:error, "malformed apply request"} = Executor.apply_executor(%{})
    assert {:error, "malformed apply request"} = Executor.apply_executor(%{"generation" => "gen-1"})
    assert {:error, "malformed update request"} = Executor.update_executor(%{})
    assert {:error, "malformed update request"} = Executor.update_executor(%{"step" => 42})
  end

  test "a confirm for a generation the built plan does not match refuses stale" do
    # The fixture home's freshly collected plan carries the checkout's real
    # (digest) generation; "gen-1" can never match it, so this pins the
    # confirm-exactly-what-you-saw contract at the seam. The refusal happens
    # before the backend runs: nothing is written to the fixture home.
    assert {:error, message} = Executor.apply_executor(%{"generation" => "gen-1", "entries" => []})
    assert message =~ "stale plan"
    assert message =~ "gen-1"
  end

  test "unknown lifecycle steps are refused by the engine, message verbatim" do
    assert {:error, message} = Executor.update_executor(%{"step" => "reboot"})
    assert message =~ "unknown lifecycle step"
  end
end
