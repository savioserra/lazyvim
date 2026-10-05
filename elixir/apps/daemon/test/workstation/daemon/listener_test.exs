defmodule Workstation.Daemon.ListenerTest do
  use ExUnit.Case, async: false

  # The whole tree binds a real unix socket against a per-test home, so every
  # test in here is serial and never touches the real HOME (env override is
  # the engine's own contract: WORKSTATION_HOME wins over HOME).
  alias Workstation.Core.EngineState
  alias Workstation.Daemon.{EventBus, Listener, Protocol, Sessions}

  setup do
    home = Path.join(System.tmp_dir!(), "b6-daemon-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")
      File.rm_rf!(home)
    end)

    %{home: home, path: Listener.socket_path(home)}
  end

  defp boot_tree do
    sup = start_supervised!(Workstation.Daemon.Application.supervisor_spec())

    wait_for_file(Listener.socket_path())
    sup
  end

  defp wait_for_file(path, tries \\ 100)

  defp wait_for_file(_path, 0), do: flunk("listener socket never appeared")

  defp wait_for_file(path, tries) do
    if File.exists?(path), do: :ok, else: (Process.sleep(20) && wait_for_file(path, tries - 1))
  end

  defp connect(path) do
    {:ok, sock} = :socket.open(:local, :stream, :default)
    :ok = :socket.connect(sock, %{family: :local, path: String.to_charlist(path)}, 2_000)
    sock
  end

  # Raw connect probe used by takeover waits; returns :ok | {:error, reason}.
  defp connect_result(path) do
    {:ok, sock} = :socket.open(:local, :stream, :default)

    try do
      :socket.connect(sock, %{family: :local, path: String.to_charlist(path)}, 500)
    after
      :socket.close(sock)
    end
  end

  defp roundtrip(sock, body) do
    :ok = :socket.send(sock, Protocol.encode_frame(body))
    read_reply(sock)
  end

  defp read_reply(sock) do
    {:ok, header} = :socket.recv(sock, 4, 2_000)
    <<length::unsigned-big-integer-size(32)>> = header
    {:ok, payload} = recv_exact(sock, length, 2_000, [])
    Jason.decode!(payload)
  end

  defp recv_exact(_sock, 0, _budget, chunks), do: {:ok, IO.iodata_to_binary(Enum.reverse(chunks))}

  defp recv_exact(sock, remaining, budget, chunks) do
    case :socket.recv(sock, remaining, budget) do
      {:ok, data} -> recv_exact(sock, remaining - byte_size(data), budget, [data | chunks])
      {:error, reason} -> {:error, reason}
    end
  end

  defp hello_request(id \\ "t1"), do: Jason.encode!(%{"v" => 1, "id" => id, "op" => "hello", "params" => %{"protocol" => "workstation.daemon/1"}})

  # --- socket file guarding -------------------------------------------------

  test "socket directory and socket file are private and owner-guarded", %{path: path} do
    boot_tree()
    dir = Path.dirname(path)

    assert %{type: "directory", uid: uid, mode: mode} = EngineState.lstat(dir)
    assert uid == EngineState.uid()
    assert :erlang.band(mode, 0o077) == 0

    assert %{type: type, uid: ^uid, mode: sock_mode} = EngineState.lstat(path)
    assert type != "link"
    assert sock_mode == 0o600
  end

  # --- end-to-end: peercred path + handshake + overlay ---------------------

  test "same-uid peer authenticates and completes hello + theme.resolve", %{path: path} do
    boot_tree()

    dark_base =
      Map.new(Workstation.Core.Theme.Tokens.palette(:dark), fn {role, hex} -> {Atom.to_string(role), hex} end)

    sock = connect(path)

    reply = roundtrip(sock, hello_request())
    assert reply["ok"] == true
    assert reply["id"] == "t1"
    assert reply["result"]["protocol"] == "workstation.daemon/1"
    assert reply["result"]["caps"]["max_request_bytes"] == Protocol.max_request_bytes()

    theme =
      Jason.encode!(%{
        "v" => 1,
        "id" => "t2",
        "op" => "theme.resolve",
        "params" => %{"appearance" => "dark", "overlays" => [%{"from" => "brand", "set" => %{"accent" => "#ff0000"}}]}
      })

    assert %{"ok" => true, "id" => "t2", "result" => %{"colors" => colors}} = roundtrip(sock, theme)
    assert colors["accent"] == "#ff0000"
    # base palette survives where no overlay touched it (palette/1 returns
    # ordered {atom, hex} pairs; the wire map is string-keyed)
    assert colors["bg"] == dark_base["bg"]

    # unknown op is a protocol error, connection stays usable
    assert %{"ok" => false, "error" => %{"code" => "unknown_op"}} = roundtrip(sock, ~s({"v":1,"id":"t3","op":"nope"}))
    assert %{"ok" => true} = roundtrip(sock, hello_request("t4"))

    :socket.close(sock)
  end

  # --- takeover -------------------------------------------------------------

  # The two takeover branches are exercised as separate tests rather than a
  # boot/stop/reboot sequence: ExUnit's supervised-child teardown is an
  # asynchronous process-tree kill whose exact completion point is not
  # observable from the test, which made a same-path re-bind racy (a failing
  # boot/stop/reboot sequence is reproduced and shown to work outside ExUnit;
  # see the b6 lane report). Each test here drives one branch deterministically.

  test "a live daemon refuses a second listener and keeps serving", %{home: home, path: path} do
    boot_tree()

    # A second listener while this one is alive must refuse with already_running
    # (its takeover probe completed a hello handshake against the live peer).
    # The raw start_link is contained in a throwaway trapping task: its init
    # exits {:already_running, path} and the gen start_link handshake interplay
    # with ExUnit's linked OnExitHandler can leak that exit to the test process,
    # killing the test despite the {:error, ...} return. A task that traps
    # exits absorbs the signal; the test only ever sees the plain message.
    me = self()

    {:ok, _task} =
      Task.start(fn ->
        Process.flag(:trap_exit, true)
        send(me, {:second_listener, Listener.start_link(home: home, name: :listener_second)})
      end)

    assert_receive {:second_listener, {:error, {:already_running, ^path}}}, 2_000

    # The refused listener must not have disturbed the live generation.
    sock = connect(path)
    assert %{"ok" => true} = roundtrip(sock, hello_request("after-refusal"))
    :socket.close(sock)
  end

  test "a dead stale socket at the path is taken over", %{path: path} do
    # Fabricate a stale endpoint exactly the way a crashed daemon leaves one:
    # a bound-then-closed listen socket whose inode outlives its fd.
    File.mkdir_p!(Path.dirname(path))
    {:ok, stale} = :socket.open(:local, :stream, :default)
    :ok = :socket.bind(stale, %{family: :local, path: String.to_charlist(path)})
    :ok = :socket.listen(stale, 1)
    :ok = :socket.close(stale)

    assert File.exists?(path)
    assert connect_result(path) == {:error, :econnrefused}

    # The fresh tree sees EADDRINUSE, probes (refused -> dead), unlinks the
    # stale inode and rebinds successfully.
    start_supervised!(Workstation.Daemon.Application.supervisor_spec())
    wait_for_file(path)

    sock = connect(path)
    assert %{"ok" => true} = roundtrip(sock, hello_request("after-takeover"))
    :socket.close(sock)
  end

  test "a non-socket file at the socket path is refused, never deleted", %{home: home, path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "not a socket")

    # A supervisor-wrapped child failure arrives as {reason, {:child, ...}};
    # only the reason is contractual, the child record is supervisor plumbing.
    assert {:error, {{:socket_path_not_owned, ^path}, _child_record}} = start_supervised({Listener, home: home})

    # The daemon never deleted the foreign file.
    assert File.read!(path) == "not a socket"
  end

  # --- session cap ------------------------------------------------------------

  test "Sessions refuses work beyond its concurrency ceiling" do
    start_supervised!(Sessions)

    child = fn ->
      %{id: make_ref(), restart: :temporary, start: {Task, :start_link, [fn -> Process.sleep(:infinity) end]}}
    end

    for _ <- 1..Sessions.max_sessions(), do: {:ok, _} = DynamicSupervisor.start_child(Sessions, child.())
    assert Sessions.count_sessions() == Sessions.max_sessions()
    assert {:error, :max_children} = DynamicSupervisor.start_child(Sessions, child.())
  end

  # --- wire framing edges (the serve loop's read_exact/3 + budget branches) --

  describe "wire framing edges" do
    test "a frame delivered in fragments is reassembled and served", %{path: path} do
      boot_tree()
      sock = connect(path)

      # Length-prefixed streams always fragment in transit; the session must
      # accumulate chunks across separate socket reads until the full frame.
      <<header::binary-size(4), body::binary>> = Protocol.encode_frame(hello_request("fragmented"))
      half = div(byte_size(body), 2)
      <<chunk_a::binary-size(half), chunk_b::binary>> = body

      :ok = :socket.send(sock, header)
      Process.sleep(20)
      :ok = :socket.send(sock, chunk_a)
      Process.sleep(20)
      :ok = :socket.send(sock, chunk_b)

      assert %{"ok" => true, "id" => "fragmented"} = read_reply(sock)
      :socket.close(sock)
    end

    test "an oversized frame header is refused with bad_frame and the connection closes", %{path: path} do
      boot_tree()
      sock = connect(path)

      :ok = :socket.send(sock, <<Protocol.max_request_bytes() + 1::unsigned-big-integer-size(32)>>)

      assert %{
               "ok" => false,
               "error" => %{
                 "code" => "bad_frame",
                 "message" => "request length outside the protocol cap"
               }
             } = read_reply(sock)

      # A length-prefixed stream cannot resync after a bad header: the peer
      # sees the protocol error, then the close.
      assert {:error, :closed} = :socket.recv(sock, 1, 2_000)
      :socket.close(sock)
    end

    test "a version-mismatched hello closes the connection without any reply", %{path: path} do
      boot_tree()
      sock = connect(path)

      stale_hello =
        Jason.encode!(%{
          "v" => 1,
          "id" => "stale",
          "op" => "hello",
          "params" => %{"protocol" => "workstation.daemon/0"}
        })

      :ok = :socket.send(sock, Protocol.encode_frame(stale_hello))

      # No frame of the current generation could be meaningful to a peer that
      # announced a different protocol name: it must see silence, then close —
      # never a reply (recv returns data => fail; closed => contract held).
      assert {:error, :closed} = :socket.recv(sock, 1, 2_000)
      :socket.close(sock)
    end

    test "the tree publishes session and op lifecycle events over the EventBus", %{path: path} do
      boot_tree()

      :ok = EventBus.subscribe(:session)
      :ok = EventBus.subscribe(:op)

      uid = EngineState.uid()
      sock = connect(path)
      assert %{"ok" => true} = roundtrip(sock, hello_request("events"))
      :socket.close(sock)

      # The served roundtrip proves both lifecycle events already fired.
      assert_receive {:daemon_event, :session, {:session_opened, ^uid}}
      assert_receive {:daemon_event, :op, {:op_served, "hello"}}
    end
  end

  # --- credential decoding (peercred layout is pinned to Linux ucred) --------

  describe "credential decoding" do
    test "ucred_uid/1 returns the SECOND field (struct ucred = pid, uid, gid)" do
      assert {:ok, 1000} = Listener.ucred_uid(<<7::native-signed-integer-size(32), 1000::native-signed-integer-size(32), 1000::native-signed-integer-size(32)>>)
      assert :invalid = Listener.ucred_uid(<<1, 2, 3>>)
      assert :invalid = Listener.ucred_uid(<<-1::native-signed-integer-size(32), -1::native-signed-integer-size(32), -1::native-signed-integer-size(32)>>)
    end
  end
end
