defmodule Workstation.Daemon.GenerationTest do
  @moduledoc """
  The daemon's release-generation rendezvous gate
  (`Workstation.Daemon.Generation`) — the fix for the 2026-10-19 incident:
  `workstation update` rebuilt the installed release while a daemon node
  spawned/booted against the same tree, and that node went on serving
  corrupt evaluations for EVERY read verb and the apply step until the
  operator TERMed the beam by pid. The contract pinned here:

  * the listener pins the node's generation at boot and refuses to become
    a daemon when the node PROVABLY is not the installed release (its own
    root's stamp and the installed release's stamp are both readable and
    differ) — a known-stale node never binds the state socket;
  * every HELLO is a rendezvous: a node the release changed (or landed)
    under refuses the handshake with `stale_generation` and schedules its
    graceful self-stop, so the client's ensure-daemon respawns a clean
    node from the fully staged installed release — the incident's
    every-verb-fails-until-TERM state becomes a one-op refusal plus an
    automatic respawn;
  * an unreadable/absent installed stamp is `:undecided` (fresh machine,
    dev home) and serves — the engine refuses to guess, never to serve
    the undecided case as stale.

  The end-to-end block boots the REAL supervisor spec against a sandboxed
  home and drives raw protocol frames, so the race shape (node booted,
  release stamp lands afterwards) is reproduced literally: the tree must
  answer the first hello, refuse the second, and go away on its own.
  """

  use ExUnit.Case, async: false

  alias Workstation.Core.EngineState
  alias Workstation.Daemon.{Generation, Listener, Protocol, Shutdown}

  @installed_stamp "246a6cb631a0deadbeef00000000000000000000ffffffffffffffffffff"

  setup do
    home =
      Path.join(System.tmp_dir!(), "ws-generation-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(home)

    previous_home = System.get_env("WORKSTATION_HOME")
    previous_root = Application.get_env(:daemon, :generation_root)
    System.put_env("WORKSTATION_HOME", home)
    Application.delete_env(:daemon, :generation_root)
    Generation.reset()

    on_exit(fn ->
      if previous_home,
        do: System.put_env("WORKSTATION_HOME", previous_home),
        else: System.delete_env("WORKSTATION_HOME")

      case previous_root do
        nil -> Application.delete_env(:daemon, :generation_root)
        root -> Application.put_env(:daemon, :generation_root, root)
      end

      Generation.reset()
      Shutdown.reset()
      Application.delete_env(:daemon, :shutdown_hook)
      File.rm_rf!(home)
    end)

    %{home: home, stamp_path: Generation.stamp_path(home)}
  end

  # --- identity and verdict semantics ---------------------------------------

  test "pin records the node's generation and own/0 answers it" do
    assert Generation.pin(own: "gen-a") == "gen-a"
    assert Generation.own() == "gen-a"

    Generation.reset()
    # Unpinned, the identity falls back to this VM's own release root
    # (unstamped in a mix env — the path fallback spelling).
    assert Generation.own() == to_string(:code.root_dir())
  end

  test "verdict: a readable installed stamp equal to the generation is fresh" do
    home = unique_home()

    File.mkdir_p!(Path.dirname(Generation.stamp_path(home)))
    File.write!(Generation.stamp_path(home), @installed_stamp <> "\n")

    assert Generation.verdict(home, @installed_stamp) == :fresh
  end

  test "verdict: a readable installed stamp that differs is stale, naming both" do
    home = unique_home()

    File.mkdir_p!(Path.dirname(Generation.stamp_path(home)))
    File.write!(Generation.stamp_path(home), @installed_stamp)

    assert {:stale, "gen-old", @installed_stamp} = Generation.verdict(home, "gen-old")
  end

  test "verdict: an absent or unreadable installed stamp is undecided, never stale" do
    home = unique_home()

    assert Generation.verdict(home, "anything") == :undecided

    File.mkdir_p!(Path.dirname(Generation.stamp_path(home)))
    File.write!(Generation.stamp_path(home), "")
    # A torn/empty stamp reads as what it is (an empty stamp — the
    # installer's `|| : > .built-from` arm), a decision, not a guess.
    assert {:stale, _, ""} = Generation.verdict(home, "gen-x")
    assert Generation.verdict(home, "") == :fresh
  end

  test "boot_verdict fires only on the provable release-vs-release mismatch" do
    own_root = Path.join(EngineState.home(), "own-release-root")
    File.mkdir_p!(own_root)
    File.write!(Path.join(own_root, ".built-from"), "gen-own\n")
    File.mkdir_p!(Path.dirname(Generation.stamp_path(EngineState.home())))
    File.write!(Generation.stamp_path(EngineState.home()), @installed_stamp)

    assert {:stale, "gen-own", @installed_stamp} =
             Generation.boot_verdict(EngineState.home(), own_root)

    # An unstamped node root (dev/mix run) cannot prove anything at boot.
    dev_root = Path.join(EngineState.home(), "dev-root")
    File.mkdir_p!(dev_root)

    assert Generation.boot_verdict(EngineState.home(), dev_root) == :undecided

    # Equal stamps are the fresh node.
    File.write!(Path.join(own_root, ".built-from"), @installed_stamp <> "\n")

    assert Generation.boot_verdict(EngineState.home(), own_root) == :fresh
  end

  test "the refusal message names both generations and the recovery" do
    message = Generation.refusal_message("gen-old", "gen-new")

    assert message =~ "gen-old"
    assert message =~ "gen-new"
    assert message =~ "workstation daemon stop"
  end

  # --- the listener refuses to bind a provably stale node --------------------

  test "a node provably not the installed release never binds the socket", %{
    home: home,
    stamp_path: stamp_path
  } do
    own_root = Path.join(home, "foreign-release-root")
    File.mkdir_p!(own_root)
    File.write!(Path.join(own_root, ".built-from"), "gen-old\n")
    File.mkdir_p!(Path.dirname(stamp_path))
    File.write!(stamp_path, @installed_stamp)

    Application.put_env(:daemon, :generation_root, own_root)

    # The whole-spec shape: the supervisor wraps the listener's boot exit —
    # the exact tuple `Workstation.Daemon.Boot.run/0` unwraps into
    # `{:error, {:stale_generation, own, installed}}` for the CLI verb.
    assert {:error,
            {{:shutdown,
              {:failed_to_start_child, Listener, {:stale_generation, "gen-old", @installed_stamp}}},
             _child}} = start_supervised(Workstation.Daemon.Application.supervisor_spec())

    refute File.exists?(Listener.socket_path(home)),
           "a boot-refused generation must never leave a bound socket"
  end

  # --- the race shape, end to end ---------------------------------------------

  test "a node the release lands under refuses hello, stops itself, and the respawn serves", %{
    home: home,
    stamp_path: stamp_path
  } do
    me = self()

    # The graceful self-stop is hooked: a supervisor-spec test tree must not
    # halt the mix run, but the socket-node removal and the stop reason are
    # the real sequence (ShutdownTest pins the mechanics).
    Application.put_env(:daemon, :shutdown_hook, fn _delay, reason ->
      send(me, {:generation_stop, reason})
    end)

    # 1. The node boots BEFORE the release exists (the incident's spawn) and
    #    answers hello normally, advertising its pinned generation.
    start_supervised!(Workstation.Daemon.Application.supervisor_spec())
    wait_for_file(Listener.socket_path(home))

    %{ok: true, result: %{"release" => boot_release}} = hello_roundtrip(home)
    assert is_binary(boot_release) and boot_release != ""

    # 2. THE RACE: the release lands under the running node (the installer's
    #    stamp write — what `workstation update`'s refresh does mid-chain).
    File.mkdir_p!(Path.dirname(stamp_path))
    File.write!(stamp_path, @installed_stamp <> "\n")

    # 3. The next rendezvous refuses fail-closed and names both generations.
    #    (On the pre-fix code the hello kept answering ok:true and the node
    #    went on serving corrupt evaluations — exactly the incident.)
    reply = hello_roundtrip(home)

    assert %{ok: false, error: %{"code" => "stale_generation", "message" => message}} = reply
    assert message =~ boot_release
    assert message =~ @installed_stamp

    # 4. The daemon stops ITSELF: the socket node goes away without any
    #    client-side kill, and the stop names the reason.
    assert_receive {:generation_stop, reason}, 5_000
    assert reason =~ "stale generation"
    wait_until(5_000, fn -> not File.exists?(Listener.socket_path(home)) end)

    stop_supervised!(Workstation.Daemon.Supervisor)
    Shutdown.reset()

    # 5. The respawn: ensure-daemon spawns from the installed release, whose
    #    stamp the new node pins — the rendezvous proves fresh and serves.
    matching_root = Path.join(home, "installed-release-root")
    File.mkdir_p!(matching_root)
    File.write!(Path.join(matching_root, ".built-from"), @installed_stamp <> "\n")
    Application.put_env(:daemon, :generation_root, matching_root)

    start_supervised!(Workstation.Daemon.Application.supervisor_spec())
    wait_for_file(Listener.socket_path(home))

    assert %{ok: true, result: %{"release" => @installed_stamp}} = hello_roundtrip(home)
  end

  test "an undecided home (no installed stamp) serves normally", %{home: home} do
    start_supervised!(Workstation.Daemon.Application.supervisor_spec())
    wait_for_file(Listener.socket_path(home))

    assert %{ok: true, result: %{"release" => release}} = hello_roundtrip(home)
    assert release == Generation.own()
  end

  # --- raw protocol helpers (listener_test's harness, generation-scoped) -----

  defp unique_home do
    Path.join(System.tmp_dir!(), "ws-generation-unit-#{System.unique_integer([:positive])}")
  end

  defp hello_roundtrip(home) do
    sock = connect(Listener.socket_path(home))

    body =
      Jason.encode!(%{
        "v" => 1,
        "id" => "gen",
        "op" => "hello",
        "params" => %{"protocol" => Protocol.protocol_name()}
      })

    :ok = :socket.send(sock, Protocol.encode_frame(body))

    {:ok, header} = :socket.recv(sock, 4, 2_000)
    <<length::unsigned-big-integer-size(32)>> = header
    {:ok, payload} = recv_exact(sock, length, 2_000, [])
    :socket.close(sock)

    case Jason.decode!(payload) do
      %{"ok" => true, "result" => result} -> %{ok: true, result: result}
      %{"ok" => false, "error" => error} -> %{ok: false, error: error}
    end
  end

  defp recv_exact(_sock, 0, _budget, chunks), do: {:ok, IO.iodata_to_binary(Enum.reverse(chunks))}

  defp recv_exact(sock, remaining, budget, chunks) do
    case :socket.recv(sock, remaining, budget) do
      {:ok, data} -> recv_exact(sock, remaining - byte_size(data), budget, [data | chunks])
      other -> other
    end
  end

  defp connect(path) do
    {:ok, sock} = :socket.open(:local, :stream, :default)
    :ok = :socket.connect(sock, %{family: :local, path: String.to_charlist(path)}, 2_000)
    sock
  end

  defp wait_for_file(path, tries \\ 100)

  defp wait_for_file(_path, 0), do: flunk("listener socket never appeared")

  defp wait_for_file(path, tries) do
    if File.exists?(path), do: :ok, else: Process.sleep(20) && wait_for_file(path, tries - 1)
  end

  defp wait_until(budget_ms, fun, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + budget_ms

    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition not met within #{budget_ms}ms")

      true ->
        Process.sleep(50)
        wait_until(budget_ms, fun, deadline)
    end
  end
end
