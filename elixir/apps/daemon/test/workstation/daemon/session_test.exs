defmodule Workstation.Daemon.SessionTest do
  @moduledoc """
  Unit pins for the session's authentication decision — the load-bearing
  half of the fail-closed peercred ruling (b6 lane): an undecodable
  credential, a symlinked socket path, a foreign-uid peer and an absent
  socket are all refused, and only the real socket owned by the daemon's
  uid is served. These branches are pure functions over a real filesystem
  fixture, so they need no accepted connection to exercise (the end-to-end
  suite can only reach the same-uid happy path as the current account).
  """

  use ExUnit.Case, async: false

  # A real unix socket is bound so the type guard sees exactly the lstat
  # shape production hands it (a socket file, never a link).
  alias Workstation.Core.EngineState
  alias Workstation.Daemon.Session

  setup do
    home = Path.join(System.tmp_dir!(), "b6-session-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")
      File.rm_rf!(home)
    end)

    %{dir: home}
  end

  defp bind_socket(dir, name) do
    path = Path.join(dir, name)
    {:ok, sock} = :socket.open(:local, :stream, :default)
    :ok = :socket.bind(sock, %{family: :local, path: String.to_charlist(path)})

    on_exit(fn ->
      _ = :socket.close(sock)
      File.rm(path)
    end)

    path
  end

  test "an undecodable peer credential is refused", %{dir: dir} do
    path = bind_socket(dir, "invalid.sock")
    refute Session.authorize?(:invalid, EngineState.uid(), path)
  end

  test "a symlinked socket path is refused (no-follow redirect defense)", %{dir: dir} do
    real = bind_socket(dir, "real.sock")
    link = Path.join(dir, "link.sock")
    File.ln_s!(real, link)

    owner = EngineState.uid()
    refute Session.authorize?(owner, owner, link)
  end

  test "a foreign-uid peer is refused even on a real socket path", %{dir: dir} do
    path = bind_socket(dir, "foreign.sock")
    owner = EngineState.uid()

    refute Session.authorize?(owner + 1, owner, path)
  end

  test "an absent socket path is refused", %{dir: dir} do
    owner = EngineState.uid()
    refute Session.authorize?(owner, owner, Path.join(dir, "never-bound.sock"))
  end

  test "the socket owner is authorized on a real socket path", %{dir: dir} do
    path = bind_socket(dir, "served.sock")
    owner = EngineState.uid()

    assert Session.authorize?(owner, owner, path)
  end
end
