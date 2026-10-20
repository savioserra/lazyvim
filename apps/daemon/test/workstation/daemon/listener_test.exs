defmodule Workstation.Daemon.ListenerTest do
  use ExUnit.Case, async: false

  # Fixture homes are cross-VM collision-proof: `System.unique_integer/1`
  # restarts its sequence in every `mix test` VM, so a home that outlives its
  # run (a killed run's leftovers) is re-drawn verbatim by a later one. The
  # boot millisecond in base36 never repeats across VMs, any same-named
  # leftover is swept before use, and the home is removed on exit (the full
  # note lives in apps/daemon/test/workstation/daemon/generation_test.exs).
  defp unique_home(prefix) do
    token = Integer.to_string(:os.system_time(:millisecond), 36)
    home = Path.join(System.tmp_dir!(), "#{prefix}-#{token}")

    File.rm_rf!(home)
    on_exit(fn -> File.rm_rf!(home) end)
    home
  end


  # The whole tree binds a real unix socket against a per-test home, so every
  # test in here is serial and never touches the real HOME (env override is
  # the engine's own contract: WORKSTATION_HOME wins over HOME).
  alias Workstation.Core.EngineState
  alias Workstation.Daemon.{CapabilityRegistry, EventBus, Listener, Protocol, Sessions}

  setup do
    home = unique_home("b6-daemon-test")
    File.mkdir_p!(home)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")
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

    test "xucred_uid/1 returns the SECOND field (struct xucred = version, uid, ...)" do
      assert {:ok, 501} =
               Listener.xucred_uid(
                 <<0::native-unsigned-integer-size(32), 501::native-signed-integer-size(32),
                   1::native-signed-integer-size(32), 0::unsigned-integer-size(32)>>
               )

      # Too short to carry version + uid, or a negative (sentinel) uid.
      assert :invalid = Listener.xucred_uid(<<1, 2, 3>>)

      assert :invalid =
               Listener.xucred_uid(
                 <<0::native-unsigned-integer-size(32), -1::native-signed-integer-size(32)>>
               )
    end
  end

  # --- platform proof resolution (the darwin degrade is explicit) -----------

  describe "platform socket proof" do
    test "resolve_proof/0 answers from the live platform" do
      case :os.type() do
        # Linux CI: the kernel sentinel proves SO_PEERCRED live — the proof,
        # option spelling and flavor are byte-identical to the original ruling.
        {:unix, :linux} ->
          assert {:ok, %{mode: :peercred, native: {1, 17}, flavor: :ucred}} = Listener.resolve_proof()

        # Darwin acceptance: a reachable LOCAL_PEERCRED is preferred; anything
        # less degrades to the recorded dir-owner proof — never a boot failure.
        _other ->
          assert {:ok, %{mode: mode}} = Listener.resolve_proof()
          assert mode in [:peercred, :dir_owner]
      end
    end

    test "an unsupported SO_PEERCRED prefers the darwin xucred proof when it answers" do
      linux = fn -> {:error, :eopnotsupp} end

      darwin = fn ->
        {:ok,
         <<0::native-unsigned-integer-size(32), 501::native-signed-integer-size(32),
           0::unsigned-integer-size(32)>>}
      end

      assert {:ok, %{mode: :peercred, native: {0, 1}, flavor: :xucred}} =
               Listener.resolve_proof(linux, darwin)
    end

    test "an unprovable darwin read degrades EXPLICITLY to the recorded dir-owner proof" do
      linux = fn -> {:error, :eopnotsupp} end
      darwin = fn -> {:error, :enotconn} end

      assert {:ok, %{mode: :dir_owner, why: {:peercred_unproven, :enotconn}}} =
               Listener.resolve_proof(linux, darwin)

      # The audit marker names the weaker proof — never a silent peercred claim.
      assert Listener.proof_marker(%{mode: :dir_owner, why: {:peercred_unproven, :enotconn}}) ==
               "dir-owner"
    end

    test "a malformed darwin xucred degrades to dir-owner with the recorded reason" do
      linux = fn -> {:error, :eopnotsupp} end
      darwin = fn -> {:ok, <<1, 2, 3>>} end

      assert {:ok, %{mode: :dir_owner, why: {:peercred_unproven, :malformed_xucred}}} =
               Listener.resolve_proof(linux, darwin)
    end

    test "a NON-unsupported failure on the primary (Linux) arm still fails closed" do
      linux = fn -> {:error, :eperm} end
      darwin = fn -> flunk("darwin probe must not run when Linux fails closed") end

      assert {:error, :eperm} = Listener.resolve_proof(linux, darwin)
    end

    test "the default boot records its resolved proof marker in hello", %{path: path} do
      boot_tree()

      {:ok, proof} = Listener.resolve_proof()
      expected_marker = Listener.proof_marker(proof)

      sock = connect(path)
      reply = roundtrip(sock, hello_request("proof-marker"))
      assert %{"ok" => true, "result" => %{"proof" => ^expected_marker}} = reply
      :socket.close(sock)
    end
  end

  # --- dir-owner proof: the explicit degrade, exercised end to end -----------

  @dir_owner_proof %{mode: :dir_owner, why: {:peercred_unproven, :forced_test}}

  # The production tree's rest_for_one order with the proof FORCED to the
  # degrade branch: the Linux CI box has no real LOCAL_PEERCRED to fall back
  # from, so the forced proof is how the darwin branch gets exercised here.
  defp boot_dir_owner_tree(home) do
    start_supervised!({Listener, home: home, proof: @dir_owner_proof})
    start_supervised!(Sessions)
    start_supervised!(EventBus)
    start_supervised!(CapabilityRegistry)
    wait_for_file(Listener.socket_path())
  end

  test "a dir-owner generation serves same-uid peers and records the marker", %{home: home, path: path} do
    boot_dir_owner_tree(home)

    uid = EngineState.uid()
    :ok = EventBus.subscribe(:session)

    sock = connect(path)
    assert %{"ok" => true, "result" => %{"proof" => "dir-owner"}} = roundtrip(sock, hello_request("dir-owner"))
    :socket.close(sock)

    # The deduced owner uid rides the same lifecycle event shape.
    assert_receive {:daemon_event, :session, {:session_opened, ^uid}}
  end

  test "a broken ownership chain is refused under the dir-owner proof", %{home: home, path: path} do
    boot_dir_owner_tree(home)

    # The 0700 dir IS the boundary in this mode: widening it breaks the
    # proof and the connection is refused at accept time (fail closed,
    # never served — the chmod race can only ever lose connections).
    File.chmod!(Path.dirname(path), 0o755)

    sock = connect(path)
    :ok = :socket.send(sock, Protocol.encode_frame(hello_request("tampered")))

    # The refusal tears the connection down with the hello frame still
    # unread — the kernel may answer the close with RST (econnreset) or a
    # plain FIN (closed); both prove the same thing: no reply, no service.
    assert {:error, reason} = :socket.recv(sock, 1, 2_000)
    assert reason in [:closed, :econnreset]
    :socket.close(sock)
  end

  # --- per-connection crash-proofing -----------------------------------------

  # A proof flavor with no decode clause: every connection's credential read
  # raises inside the per-connection path. This is the injected form of any
  # unexpected raise in serve_client/connection_peer_uid/hand_off — which,
  # before the outer rescue, propagated out of accept_loop and killed the
  # LISTENER. That listener is the FIRST child of a rest_for_one tree, so
  # one raise rolled the whole serving generation and cut every session's
  # connection mid-op (the non-stop `daemon_died` flake family). The
  # contract now: a per-connection failure costs exactly that connection —
  # refused fail-closed — and the listener keeps accepting.
  @poisoned_proof %{mode: :peercred, native: {1, 17}, flavor: :no_such_flavor}

  test "a per-connection failure is refused, never fatal to the listener", %{home: home, path: path} do
    start_supervised!({Listener, home: home, proof: @poisoned_proof})
    wait_for_file(path)

    listener_pid = Process.whereis(Listener)
    assert is_pid(listener_pid)

    # Three consecutive connections, each hitting the raise inside the
    # per-connection path. Every one must be closed by the daemon (refused
    # fail-closed — a poisoned proof serves nobody) and the listener must
    # still be alive and accepting after all of them: the failure never
    # leaves the per-connection scope.
    Enum.each(1..3, fn i ->
      sock = connect(path)

      assert {:error, reason} = :socket.recv(sock, 1, 2_000),
             "connection #{i}: the poisoned connection was served instead of refused"

      assert reason in [:closed, :econnreset]
      :socket.close(sock)
    end)

    assert Process.alive?(listener_pid), "the listener died with a per-connection failure"
    assert Process.whereis(Listener) == listener_pid
  end
end
