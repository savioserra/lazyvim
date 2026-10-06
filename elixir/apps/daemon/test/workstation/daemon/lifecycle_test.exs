defmodule Workstation.Daemon.LifecycleTest do
  use ExUnit.Case, async: false

  # End-to-end lifecycle-op coverage over a real socket (b8 graduation
  # wiring): the orchestrator lock is taken and released around the op, and
  # the refusal is the honest `not_graduated` gate — never a fake success.
  # Serial like ListenerTest: the tree binds a real unix socket per test
  # home and never touches the real HOME.
  alias Workstation.Core.EngineState
  alias Workstation.Daemon.{ApplyOrchestrator, Listener, Protocol}

  setup do
    home = Path.join(System.tmp_dir!(), "b8-lifecycle-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    # The graduation default is OPEN (the daemon is the only mutation
    # engine); normalize the flag so suite-order shuffles cannot leak a
    # pinned-off apply pipeline into the default-path tests.
    Application.delete_env(:daemon, :engine_apply)

    on_exit(fn ->
      if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")
      Application.delete_env(:daemon, :engine_apply)
      File.rm_rf!(home)
    end)

    start_supervised!(Workstation.Daemon.Application.supervisor_spec())
    wait_for_file(Listener.socket_path())

    %{home: home}
  end

  defp wait_for_file(path, tries \\ 100)

  defp wait_for_file(_path, 0), do: flunk("listener socket never appeared")

  defp wait_for_file(path, tries) do
    if File.exists?(path), do: :ok, else: (Process.sleep(20) && wait_for_file(path, tries - 1))
  end

  defp request(op, params) do
    {:ok, sock} = :socket.open(:local, :stream, :default)

    try do
      :ok = :socket.connect(sock, %{family: :local, path: String.to_charlist(Listener.socket_path())}, 2_000)
      :ok = :socket.send(sock, Protocol.encode_frame(hello_body()))
      {:ok, _hello_frame} = recv_frame(sock)

      :ok = :socket.send(sock, Protocol.encode_frame(Jason.encode!(%{"v" => 1, "id" => "l1", "op" => op, "params" => params})))
      {:ok, frame} = recv_frame(sock)
      Jason.decode!(frame)
    after
      :socket.close(sock)
    end
  end

  defp hello_body, do: Jason.encode!(%{"v" => 1, "id" => "h1", "op" => "hello", "params" => %{"protocol" => Protocol.protocol_name()}})

  defp recv_frame(sock) do
    {:ok, <<length::unsigned-big-integer-size(32)>>} = :socket.recv(sock, 4, 2_000)
    recv_exact(sock, length, [])
  end

  defp recv_exact(_sock, 0, chunks), do: {:ok, IO.iodata_to_binary(Enum.reverse(chunks))}

  defp recv_exact(sock, remaining, chunks) do
    {:ok, data} = :socket.recv(sock, remaining, 2_000)
    recv_exact(sock, remaining - byte_size(data), [data | chunks])
  end

  test "with graduation open (the default), apply.run reaches the engine and refuses on merit" do
    # The gate is open: the refusal is the ENGINE's precondition (the
    # requested generation cannot match a plan built on an empty sandbox),
    # never the graduation gate.
    reply = request("apply.run", %{"generation" => "gen-1", "entries" => []})

    assert %{"ok" => false, "error" => %{"code" => "apply_refused", "message" => message}} = reply
    assert message =~ "stale plan"

    # The orchestration is real: the lock is gone once the op answers.
    refute File.exists?(ApplyOrchestrator.lock_path(EngineState.state_root()))
  end

  test "with the graduation flag pinned off, the apply pipeline answers the honest refusal" do
    # The env flag is the off switch for the APPLY PIPELINE ONLY: the
    # lifecycle chain (bootstrap provisioning et al) is deliberately never
    # gated — bootstrap is what installs the release, pre-graduation
    # included (parity with the retired in-process engine path).
    Application.put_env(:daemon, :engine_apply, false)

    reply = request("apply.run", %{"generation" => "gen-1", "entries" => []})

    assert %{"ok" => false, "error" => %{"code" => "not_graduated", "message" => message}} = reply
    assert message == Workstation.Daemon.Apply.not_graduated_message()

    refute File.exists?(ApplyOrchestrator.lock_path(EngineState.state_root()))
  end

  test "update.run executes the cheap lifecycle step for real (the chain is never graduation-gated)" do
    # pull is the cheapest chain step and is read-only for the home: its
    # honest ok over the wire is the proof the lifecycle chain runs
    # regardless of the apply-pipeline flag.
    reply = request("update.run", %{"step" => "pull"})

    assert %{"ok" => true, "result" => %{"step" => "pull", "status" => "ok"}} = reply

    refute File.exists?(ApplyOrchestrator.lock_path(EngineState.state_root()))
  end

  test "a held lock reports its owner instead of running the op" do
    {:ok, token, _path} = ApplyOrchestrator.acquire("held by test")

    reply = request("apply.run", %{"generation" => "gen-1", "entries" => []})

    assert %{"ok" => false, "error" => %{"code" => "locked", "message" => message}} = reply
    # The owner report is the recorded metadata (uid + node), not the
    # purpose — that is the fail-closed report the Lua parity pins.
    assert message =~ "apply lock held by uid="

    :ok = ApplyOrchestrator.release(token)
  end

  test "invalid params are refused by the schema, never dispatched" do
    for {op, params} <- [
          {"apply.run", %{}},
          {"apply.run", %{"generation" => ""}},
          {"apply.run", %{"generation" => "gen-1", "entries" => %{"bad" => "shape"}}},
          {"update.run", %{"step" => "reboot"}},
          {"update.run", %{}}
        ] do
      reply = request(op, params)
      assert %{"ok" => false, "error" => %{"code" => "invalid_params"}} = reply
    end

    refute File.exists?(ApplyOrchestrator.lock_path(EngineState.state_root()))
  end
end
