defmodule Workstation.DaemonTest do
  use ExUnit.Case, async: false

  @moduledoc """
  The daemon supervision tree's boot contract: rest_for_one order over the
  infrastructure children, capability children flattened in after them, and
  the socket actually bound under the pinned home. Serialization is nix's
  own switch lock — the daemon serves reads and pubsub only.
  """

  # Fixture homes are cross-VM collision-proof: `System.unique_integer/1`
  # restarts its sequence in every `mix test` VM, so a home that outlives its
  # run (a killed run's leftovers) is re-drawn verbatim by a later one.
  defp unique_home(prefix) do
    token = Integer.to_string(:os.system_time(:millisecond), 36)
    home = Path.join(System.tmp_dir!(), "#{prefix}-#{token}")

    File.rm_rf!(home)
    on_exit(fn -> File.rm_rf!(home) end)
    home
  end

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
    Workstation.Daemon.TaskSupervisor
  ]

  setup do
    home = unique_home("b6-daemon-tree")
    File.mkdir_p!(home)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")
    end)

    %{home: home}
  end

  test "daemon supervision tree boots rest_for_one in contract order", %{home: home} do
    start_supervised!(Workstation.Daemon.Application.supervisor_spec())

    names = for {name, _, _, _} <- Supervisor.which_children(Workstation.Daemon.Supervisor), do: name

    # which_children reports newest-first, i.e. REVERSE start order; the
    # contract pins the start order (rest_for_one), so compare reversed.
    assert Enum.reverse(names) == @infrastructure ++ [
             Workstation.Daemon.Overlay
           ]

    # The listener served its socket under the temp home.
    assert File.exists?(Listener.socket_path(home))
  end
end
