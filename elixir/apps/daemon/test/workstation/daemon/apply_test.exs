defmodule Workstation.Daemon.ApplyTest do
  @moduledoc """
  The graduation gate around the daemon's engine applier. Ships OFF (the
  `not_graduated` refusal stays the wire answer and the lock still serializes
  the refusal), and when the flag is flipped the real pipeline runs end to
  end against a SANDBOX home: server-side plan from a sandbox catalog
  fixture, backend apply through the pinned argv, journal record, and the
  `locked` mapping under contention. The update lifecycle re-uses this
  module as its `apply` step (Workstation.Daemon.Update); its mutation
  steps answer the same gate and its read-only steps serve now.
  """

  use ExUnit.Case, async: false

  alias Workstation.Core.{Catalog, Digest, EngineState, Graph, Source}
  alias Workstation.Daemon.{Apply, Listener, Protocol}

  setup do
    home = Path.join(System.tmp_dir!(), "c1-daemon-apply-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    # The orchestrator (and listener) run for every case: the gate-on path
    # takes the real apply lock through the supervised GenServer.
    start_supervised!(Workstation.Daemon.Application.supervisor_spec())

    on_exit(fn ->
      if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")
      Application.delete_env(:daemon, :engine_apply)
      File.rm_rf!(home)
    end)

    %{home: home}
  end

  describe "the graduation gate" do
    test "ships ON by default — the daemon is THE mutation engine" do
      Application.delete_env(:daemon, :engine_apply)
      assert Apply.enabled?()
    end

    test "with the gate open, apply.run executes the real pipeline against the sandbox home", %{home: home} do
      Application.put_env(:daemon, :engine_apply, true)
      generation = fixture_plan_generation(home)
      install_fake_chezmoi(home, fixture_target(home))

      assert {:ok, %{"generation" => ^generation}} =
               Apply.run(generation, home: home, collector: fn -> {:ok, sandbox_catalog(home)} end)

      # The journal records the applied generation (the ownership claim), the
      # staged generation directory exists under the guarded root, and the
      # backend ran once with the exact documented argv.
      record = applied_record(home)
      assert record["generation"] == generation
      assert record["revision"] == 1

      # The fingerprint of the deployed target matches the plan bytes AND
      # the real file the backend wrote (the anchor's structured target
      # fingerprint: type + mode + sha256 of the deployed bytes).
      assert record["targets"][".config/fixture/rc"]["sha256"] == Digest.sha256("export FIXTURE=1\n")
      assert record["targets"][".config/fixture/rc"]["sha256"] == Digest.sha256(File.read!(Path.join(home, ".config/fixture/rc")))

      directory = Path.join([home | EngineState.state_components() ++ ["generations", generation]])
      assert File.read!(Path.join(directory, ".chezmoidata.toml")) == "fixture = true\n"
      assert File.read!(Path.join(directory, "dot_config/fixture/rc")) == "export FIXTURE=1\n"

      argv = File.read!(argv_log(home)) |> String.split("\n", trim: true)
      assert argv == ["--source", directory, "--destination", home, "apply", "--exclude", "scripts"]
    end

    test "a plan composed on a journaled home stamps the real baseline (never the pure-replay zero)", %{home: home} do
      Application.put_env(:daemon, :engine_apply, true)

      # A journal that already advanced past an earlier engine generation:
      # with the pure-replay default (journal_revision 0) still in the plan,
      # the in-lock precondition check refuses every real apply on a
      # journaled home as stale — exactly what the real host exposed.
      # The foreign generation applies to an empty target map, so the only
      # gate under test is the baseline stamp, not ownership conflicts.
      state = Path.join([home | EngineState.state_components()])
      File.mkdir_p!(Path.join(state, "journal"))
      File.chmod!(Path.join(state, "journal"), 0o700)

      File.write!(Path.join([state, "journal", "applied.json"]),
        Jason.encode!(%{
          "revision" => 2,
          "generation" => String.duplicate("a", 64),
          "at" => 1_700_000_000,
          "targets" => %{},
          "manifest" => []
        })
      )

      generation = fixture_plan_generation(home)
      install_fake_chezmoi(home, fixture_target(home))

      assert {:ok, %{"generation" => ^generation}} =
               Apply.run(generation, home: home, collector: fn -> {:ok, sandbox_catalog(home)} end)

      # The applied record advanced the REAL journal (2 -> 3) and claims the
      # new generation, proving the baseline stamp matched, not the zero.
      record = applied_record(home)
      assert record["revision"] == 3
      assert record["generation"] == generation
    end

    test "with the gate open, a contended apply lock maps to the locked protocol error", %{home: home} do
      Application.put_env(:daemon, :engine_apply, true)

      # Contention is a CROSS-PROCESS fact (a Lua one-shot apply, or another
      # daemon instance, holding the same apply.lock): the orchestrator's
      # GenServer mailbox already serializes in-daemon requests, so an
      # externally created lock file is the honest fixture. The orchestrator
      # reads the recorded owner and fails closed, never steals.
      lock = Path.join([home | EngineState.state_components() ++ ["apply.lock"]])
      File.mkdir_p!(Path.dirname(lock))
      File.write!(lock, Workstation.Core.CanonicalJSON.encode(%{"owner" => "uid=1000 node=test@host (pid 4242)"}))

      assert {:error, {"locked", message}} =
               Apply.run("any-generation", home: home, collector: fn -> {:ok, sandbox_catalog(home)} end)

      assert message == "apply lock held by uid=1000 node=test@host (pid 4242)"
    end

    test "with the gate open, the update apply step is served, not gated", %{home: _home} do
      Application.put_env(:daemon, :engine_apply, true)

      wait_for_file(Listener.socket_path())

      # Over the socket there is no sandbox collector injection: the step
      # EXECUTES and fails honestly on the sandbox home. The wire proof is
      # the code — the apply step's own failure code, never the graduation
      # gate and never the chain code.
      reply = request("update.run", %{"step" => "apply"})
      assert %{"ok" => false, "error" => %{"code" => "apply_failed"}} = reply
    end

    test "a sandbox catalog failure is an apply_refused protocol error, never a crash", %{home: home} do
      Application.put_env(:daemon, :engine_apply, true)

      assert {:error, {"apply_refused", message}} =
               Apply.run("any-generation", home: home, collector: fn -> {:error, :sandbox_failure} end)

      assert message =~ "apply plan collection failed"
    end
  end

  ## fixtures

  # Mirror of the server-side plan composition: the same Catalog → Graph →
  # Source pipeline the flag-on path runs, so the test derives the fixture
  # generation instead of hard-coding a digest.
  defp fixture_plan_generation(home) do
    catalog = Catalog.load(fixture_envelope(home))
    graph = Graph.order(%{host: catalog.host, specifications: catalog.packages})
    %Source{generation: generation} = Source.plan(%{graph: graph})
    home && generation
  end

  defp sandbox_catalog(home), do: Catalog.load(fixture_envelope(home))

  defp fixture_envelope(home) do
    %{
      "profile" => "daemon-sandbox",
      "host" => "linux",
      "home" => home,
      "assets" => %{"fixture:files/rc" => "export FIXTURE=1\n"},
      "packages" => [
        %{
          "id" => "fixture",
          "requires" => [],
          "contributes" => [
            %{
              "provider" => "chezmoi",
              "spec" => %{"asset" => "fixture:files/rc", "kind" => "file", "target" => ".config/fixture/rc"}
            },
            %{
              "provider" => "chezmoi-data",
              "spec" => %{"content" => "fixture = true\n"}
            }
          ]
        }
      ]
    }
  end

  defp applied_record(home), do: home |> state_components() |> then(&File.read!(Path.join(&1 ++ ["journal", "applied.json"]))) |> Jason.decode!()

  defp state_components(home), do: [home | EngineState.state_components()]

  defp argv_log(home), do: Path.join([home, ".local", "opt", "chezmoi", "bin", "chezmoi.argv"])

  defp install_fake_chezmoi(home, instructions) do
    bin = Path.join([home, ".local", "opt", "chezmoi", "bin", "chezmoi"])
    File.mkdir_p!(Path.dirname(bin))
    File.write!(bin <> ".instructions", instructions)

    File.write!(
      bin,
      "#!/bin/sh\nfor arg in \"$@\"; do printf '%s\\n' \"$arg\" >> \"#{bin}.argv\"; done\nsh \"#{bin}.instructions\"\n"
    )

    File.chmod!(bin, 0o755)
    bin
  end

  defp fixture_target(home) do
    destination = Path.join(home, ".config/fixture/rc")

    # The body interpolates with its REAL trailing newline (single quotes
    # preserve it through sh).
    """
    mkdir -p '#{Path.dirname(destination)}'
    printf '%s' '#{"export FIXTURE=1\n"}' > '#{destination}'
    chmod 644 '#{destination}'
    """
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
      # Ops stream progress events ahead of the reply now (the daemon owns
      # the chain); drain the event frames until the id-matched result.
      recv_result(sock, "l1")
    after
      :socket.close(sock)
    end
  end

  defp hello_body,
    do: Jason.encode!(%{"v" => 1, "id" => "h1", "op" => "hello", "params" => %{"protocol" => Protocol.protocol_name()}})

  defp recv_result(sock, id) do
    case recv_frame(sock) do
      {:ok, %{"id" => ^id} = reply} -> reply
      {:ok, %{"event" => _event}} -> recv_result(sock, id)
      {:ok, other} -> flunk("unexpected frame: " <> inspect(other))
    end
  end

  defp recv_frame(sock) do
    {:ok, <<length::unsigned-big-integer-size(32)>>} = :socket.recv(sock, 4, 2_000)
    {:ok, body} = recv_exact(sock, length, [])
    {:ok, Jason.decode!(body)}
  end

  defp recv_exact(_sock, 0, chunks), do: {:ok, IO.iodata_to_binary(Enum.reverse(chunks))}

  defp recv_exact(sock, remaining, chunks) do
    {:ok, data} = :socket.recv(sock, remaining, 2_000)
    recv_exact(sock, remaining - byte_size(data), [data | chunks])
  end
end
