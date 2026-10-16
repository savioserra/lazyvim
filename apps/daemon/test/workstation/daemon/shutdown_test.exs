defmodule Workstation.Daemon.ShutdownTest do
  @moduledoc """
  The graceful stop contract: the stop never begins its teardown before the
  stop-granting op's reply frame is provably on the wire — the delay floor
  plus the session's reply-flush ack (`Workstation.Daemon.Shutdown.reply_flushed/1`,
  called by the session after the reply reached the socket) order that
  deterministically, and a stop whose ack never comes (a vanished client)
  still fires, bounded by the flush budget. After the handshake the daemon
  drains its in-flight op tasks (their apply locks release by settling),
  removes its own socket node through the no-follow ownership proof, and
  only then exits. The tests hook the HALT (a supervisor-spec test tree
  must not die with the mix run) but run the handshake, the drain and the
  socket removal for real — the socket node is the observable the CLI's
  pre-replace wait polls, so "socket gone" must be produced by exactly this
  sequence. The hook fires in the daemon's own stop process (never the
  caller), so hooks that message the test capture `parent = self()` at
  definition time.
  """

  use ExUnit.Case, async: false

  alias Workstation.Core.EngineState
  alias Workstation.Daemon.{Listener, Protocol, Shutdown, TaskSupervisor}

  setup do
    home = Path.join(System.tmp_dir!(), "ws-shutdown-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")
      Shutdown.reset()
      Application.delete_env(:daemon, :shutdown_hook)
      Application.delete_env(:daemon, :drain_timeout_ms)
      Application.delete_env(:daemon, :reply_flush_ms)
      Application.delete_env(:daemon, :flush_wait_ms)
      File.rm_rf!(home)
    end)

    %{home: home, socket_path: Listener.socket_path(home)}
  end

  # The real boot shape (the tests below assert on the tree's own socket
  # node, so the tree must be the real one).
  defp boot_tree do
    start_supervised!(Workstation.Daemon.Application.supervisor_spec())
    wait_for_file(Listener.socket_path())
  end

  defp wait_for_file(path, tries \\ 100)

  defp wait_for_file(_path, 0), do: flunk("listener socket never appeared")

  defp wait_for_file(path, tries) do
    if File.exists?(path), do: :ok, else: (Process.sleep(20) && wait_for_file(path, tries - 1))
  end

  # Bounded poll for a predicate — the graceful sequence runs in the stop
  # process AFTER the reply now, so its observables (socket node gone, the
  # hook's side effects) land a beat after the reply instead of before it.
  defp wait_until(pred, message), do: wait_until(pred, message, 200)

  defp wait_until(_pred, message, 0), do: flunk("#{message} within the wait budget")

  defp wait_until(pred, message, tries) do
    if pred.(), do: :ok, else: (Process.sleep(10) && wait_until(pred, message, tries - 1))
  end

  defp connect(path) do
    {:ok, sock} = :socket.open(:local, :stream, :default)
    :ok = :socket.connect(sock, %{family: :local, path: String.to_charlist(path)}, 2_000)
    sock
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

  defp now_ms, do: System.monotonic_time(:millisecond)

  test "the daemon.stop rpc drains, removes the socket node, and answers ok", %{socket_path: socket_path} do
    boot_tree()

    # The halt is hooked (the test VM must survive); the handshake, the
    # drain and the socket removal run for real in the daemon's stop
    # process. The hook records the stop reason in a persistent term
    # because it fires in the stop process, not the test's.
    Application.put_env(:daemon, :shutdown_hook, fn _delay_ms, reason ->
      :persistent_term.put({__MODULE__, :hook_reason}, reason)
    end)

    Shutdown.reset()

    sock = connect(socket_path)
    hello = Jason.encode!(%{"v" => 1, "id" => "s1", "op" => "hello", "params" => %{"protocol" => Protocol.protocol_name()}})
    assert %{"ok" => true} = roundtrip(sock, hello)

    stop = Jason.encode!(%{"v" => 1, "id" => "s2", "op" => "daemon.stop", "params" => %{}})
    assert %{"ok" => true, "result" => %{"stopping" => true}} = roundtrip(sock, stop)

    # The reply is on the wire; the stop process acks past the handshake,
    # drains, and removes the socket NODE — the observable the CLI's
    # pre-replace wait polls — while the tree is still up, and the stop
    # carried the op's reason.
    wait_until(fn -> not File.exists?(socket_path) end, "the graceful stop left the socket node in place")

    assert :persistent_term.get({__MODULE__, :hook_reason}, nil) == "daemon.stop op"
    :persistent_term.erase({__MODULE__, :hook_reason})

    # A second request while a stop is pending is a daemon-side no-op (the
    # composition contract with the release-refresh handoff stop).
    assert Shutdown.stopping?()
    assert :ok = Shutdown.stop_after("second request")

    :ok = :socket.close(sock)
  end

  test "the stop never begins before the op's reply frame is on the wire (the flush ack)", %{
    socket_path: socket_path
  } do
    # THE ordering pin — and the flake's tombstone. With the timing floor
    # removed (reply_flush_ms = 0) the ONLY force ordering the teardown
    # against the reply is the session's flush ack; the pre-handshake code
    # ran the sequence inside the op task, strictly BEFORE the client could
    # have read any reply — exactly the lost race this handshake replaces.
    Application.put_env(:daemon, :reply_flush_ms, 0)

    boot_tree()

    Application.put_env(:daemon, :shutdown_hook, fn _delay_ms, reason ->
      :persistent_term.put({__MODULE__, :hook_fired_at}, now_ms())
      :persistent_term.put({__MODULE__, :hook_reason}, reason)
    end)

    Shutdown.reset()

    sock = connect(socket_path)
    hello = Jason.encode!(%{"v" => 1, "id" => "a1", "op" => "hello", "params" => %{"protocol" => Protocol.protocol_name()}})
    assert %{"ok" => true} = roundtrip(sock, hello)

    stop = Jason.encode!(%{"v" => 1, "id" => "a2", "op" => "daemon.stop", "params" => %{}})
    assert %{"ok" => true, "result" => %{"stopping" => true}} = roundtrip(sock, stop)

    # The reply frame is fully read here; the ack the session armed fires no
    # later than this point, so the hook must never have fired EARLIER.
    replied_at = now_ms()
    wait_until(fn -> :persistent_term.get({__MODULE__, :hook_fired_at}, nil) != nil end, "the stop hook fired")

    assert :persistent_term.get({__MODULE__, :hook_fired_at}) >= replied_at,
           "the stop fired before the op's reply was on the wire " <>
             "(hook at #{:persistent_term.get({__MODULE__, :hook_fired_at})}, reply read at #{replied_at})"

    assert :persistent_term.get({__MODULE__, :hook_reason}) == "daemon.stop op"
    :persistent_term.erase({__MODULE__, :hook_fired_at})
    :persistent_term.erase({__MODULE__, :hook_reason})
    :ok = :socket.close(sock)
  end

  test "an unacked stop still fires, bounded by the flush budget (a vanished client)", %{
    socket_path: _socket_path
  } do
    # The deterministic half must never hang the stop: a stop whose op_ref
    # is never acked (the client died before the reply) proceeds through
    # the flush budget alone.
    Application.put_env(:daemon, :flush_wait_ms, 300)

    parent = self()

    Application.put_env(:daemon, :shutdown_hook, fn _delay_ms, _reason ->
      send(parent, {:hook, :fired})
    end)

    Shutdown.reset()

    started = now_ms()
    assert :ok = Shutdown.stop_after("unacked stop", "op-never-acked")
    assert_receive {:hook, :fired}, 5_000

    assert now_ms() - started >= 300, "the stop did not honor the flush budget"
  end

  test "the drain waits for in-flight op tasks before the stop fires", %{socket_path: _socket_path} do
    boot_tree()

    parent = self()

    Application.put_env(:daemon, :shutdown_hook, fn _delay_ms, _reason -> send(parent, {:hook, :fired}) end)

    Shutdown.reset()

    done = :atomics.new(1, signed: false)

    {:ok, _pid} =
      Task.Supervisor.start_child(TaskSupervisor, fn ->
        Process.sleep(300)
        :atomics.put(done, 1, 1)
      end)

    started = System.monotonic_time(:millisecond)
    assert :ok = Shutdown.stop_after("drain test")

    # The hook fires only after the handshake and the drain, and the drain
    # ends only when the task tree is empty — the flag set just before the
    # task's exit must be visible, and the stop must have actually waited
    # out the sleep.
    assert_receive {:hook, :fired}, 5_000
    elapsed = System.monotonic_time(:millisecond) - started

    assert :atomics.get(done, 1) == 1, "the stop fired while an op task was still in flight"
    assert elapsed >= 250, "the drain did not wait for the in-flight task (#{elapsed}ms)"
  end

  test "a regular file at the socket path is never removed by the stop", %{home: home, socket_path: socket_path} do
    # The no-follow law: only a provably owned SOCKET node is ever unlinked.
    # Anything else at the path is left for the next boot's takeover.
    File.mkdir_p!(Path.dirname(socket_path))
    File.write!(socket_path, "not a socket")

    parent = self()

    Application.put_env(:daemon, :shutdown_hook, fn _delay_ms, _reason -> send(parent, {:hook, :fired}) end)

    Shutdown.reset()

    assert :ok = Shutdown.stop_after("foreign path test")
    assert_receive {:hook, :fired}, 5_000
    assert File.exists?(socket_path)
    assert File.read!(socket_path) == "not a socket"

    assert EngineState.home() == home
  end

  test "daemon.stop carries the daemon's own OS pid for the client's exit confirmation", %{
    socket_path: socket_path
  } do
    # The wire pid is the platform-independent source for the CLI's stop
    # ladder (darwin's xucred has no pid field; a dir-owner generation has
    # no kernel read at all) — in-process the daemon IS this test VM. The
    # halt is hooked (the test VM must survive); the reason is recorded in
    # a persistent term because the hook fires in the stop process, not
    # the test's.
    Application.put_env(:daemon, :shutdown_hook, fn _delay_ms, reason ->
      :persistent_term.put({__MODULE__, :hook_reason}, reason)
    end)

    Shutdown.reset()
    boot_tree()

    sock = connect(socket_path)

    hello =
      Jason.encode!(%{"v" => 1, "id" => "p1", "op" => "hello", "params" => %{"protocol" => Protocol.protocol_name()}})

    assert %{"ok" => true} = roundtrip(sock, hello)

    stop = Jason.encode!(%{"v" => 1, "id" => "p2", "op" => "daemon.stop", "params" => %{}})
    assert %{"ok" => true, "result" => %{"stopping" => true, "pid" => pid}} = roundtrip(sock, stop)
    assert is_integer(pid) and pid > 0
    # The daemon tree runs in this VM; the wire pid is its OS pid as an
    # integer (System.pid/0 spells it as a string).
    assert pid == String.to_integer(System.pid())
    wait_until(fn -> :persistent_term.get({__MODULE__, :hook_reason}, nil) != nil end, "the stop hook fired")
    assert :persistent_term.get({__MODULE__, :hook_reason}) == "daemon.stop op"
    :persistent_term.erase({__MODULE__, :hook_reason})
    :ok = :socket.close(sock)
  end

  test "the pending-stop marker stays idempotent across the graceful sequence" do
    parent = self()

    Application.put_env(:daemon, :shutdown_hook, fn _delay_ms, _reason -> send(parent, {:hook, :fired}) end)

    Shutdown.reset()

    assert :ok = Shutdown.stop_after("first")
    assert_receive {:hook, :fired}, 5_000
    assert :ok = Shutdown.stop_after("second")
    # Only the first request's hook fires; the pending one is a no-op.
    refute_received {:hook, :fired}
    assert Shutdown.stopping?()
  end
end
