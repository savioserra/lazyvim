defmodule Workstation.DaemonTest do
  use ExUnit.Case, async: false

  # The daemon tree binds a real unix socket, so it is only ever booted under
  # a per-test home (WORKSTATION_HOME is the engine's own override contract);
  # the real HOME is never touched by the suite.
  alias Workstation.Daemon.Listener

  # Infrastructure children are central in Application.children/0; capability
  # children flatten in after them (see CapabilitiesTest).
  @infrastructure [
    Workstation.Daemon.Listener,
    Workstation.Daemon.Sessions,
    Workstation.Daemon.EventBus,
    Workstation.Daemon.OpRegistry,
    Workstation.Daemon.CapabilityRegistry,
    Workstation.Daemon.ApplyOrchestrator,
    Workstation.Daemon.TaskSupervisor
  ]

  setup do
    home = Path.join(System.tmp_dir!(), "b6-daemon-tree-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")
      File.rm_rf!(home)
    end)

    %{home: home}
  end

  test "daemon supervision tree boots rest_for_one in contract order", %{home: home} do
    start_supervised!(Workstation.Daemon.Application.supervisor_spec())

    names = for {name, _, _, _} <- Supervisor.which_children(Workstation.Daemon.Supervisor), do: name

    # which_children reports newest-first, i.e. REVERSE start order; the
    # contract pins the start order (rest_for_one), so compare reversed.
    assert Enum.reverse(names) == @infrastructure ++ [
             Workstation.Daemon.Overlay,
             Workstation.Daemon.UpdateCheck
           ]

    # The listener served its socket under the temp home.
    assert File.exists?(Listener.socket_path(home))
  end

  test "apply orchestrator serializes on the state.lua-style fail-closed lock", %{home: home} do
    # The orchestrator resolves its state root from EngineState at boot, so
    # the per-test WORKSTATION_HOME override pins the lock file under `home`.
    start_supervised!(Workstation.Daemon.ApplyOrchestrator)

    lock_path = Workstation.Daemon.ApplyOrchestrator.lock_path(Path.join([home, ".local", "state", "workstation"]))

    # A foreign lock file (as a one-shot apply would have left it while
    # running) makes acquisition fail closed with the recorded owner.
    File.mkdir_p!(Path.dirname(lock_path))
    File.write!(lock_path, ~s({"owner":"uid=0 one-shot apply","purpose":"apply","token":"foreign"}))

    assert {:error, {:locked, "uid=0 one-shot apply", ^lock_path}} =
             Workstation.Daemon.ApplyOrchestrator.acquire("daemon generation")

    # Release only works for the recorded token, never for a bystander.
    assert File.exists?(lock_path)
    assert {:error, {:locked, _, _}} = Workstation.Daemon.ApplyOrchestrator.with_lock("daemon generation", fn -> :ran end)
  end
end
