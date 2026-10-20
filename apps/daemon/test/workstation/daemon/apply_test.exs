defmodule Workstation.Daemon.ApplyTest do
  @moduledoc """
  The graduation gate around the daemon's engine applier — RETIRED OPEN
  (`apply.run` serves the real pipeline by default; the `not_graduated`
  refusal is pinned by explicitly closing the gate in the application
  environment, and the lock still serializes the refusal). With the gate
  open the real pipeline runs end to end against a SANDBOX home:
  server-side plan from a sandbox catalog fixture, backend apply through
  the pinned argv, journal record, and the `locked` mapping under
  contention. The update lifecycle (`Workstation.Daemon.Lifecycle`)
  executes its `apply` step itself and is never graduation-gated; this
  module stays the gated `apply.run` op surface.
  """

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


  alias Workstation.Core.{Catalog, Digest, EngineState, Graph, Source}
  alias Workstation.Daemon.{Apply, Listener, Protocol}
  alias Workstation.Pipeline

  setup do
    home = unique_home("c1-daemon-apply")
    File.mkdir_p!(home)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    # The orchestrator (and listener) run for every case: the gate-on path
    # takes the real apply lock through the supervised GenServer.
    start_supervised!(Workstation.Daemon.Application.supervisor_spec())

    on_exit(fn ->
      if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")
      Application.delete_env(:daemon, :engine_apply)
    end)

    %{home: home}
  end

  describe "the generation precheck (apply.run and apply.plan)" do
    test "apply.run refuses a provably stale release before any composition", %{home: home} do
      Application.put_env(:daemon, :engine_apply, true)
      stamp_stale_release!(home)

      assert {:error, {"apply_refused", message}} =
               Apply.run("any-generation",
                 home: home,
                 engine_root: repo_root(),
                 collector: fn -> flunk("a skewed release must not evaluate the source tree") end
               )

      assert message =~ "stale engine release, refresh the release"
    end

    test "apply.plan refuses the same skew at the confirmation surface", %{home: home} do
      stamp_stale_release!(home)

      assert {:error, {"apply_refused", message}} =
               Apply.plan(home: home, engine_root: repo_root(), collector: fn -> flunk("never evaluated") end)

      assert message =~ "stale engine release, refresh the release"
    end

    test "an unstamped home (release-only install) plans as before", %{home: home} do
      # No .built-from: no provable provenance, no refusal — the surfaces
      # that applied before the precheck keep applying.
      assert {:ok, _wire} =
               Apply.plan(home: home, engine_root: repo_root(), collector: fn -> {:ok, sandbox_catalog(home)} end)
    end
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

    test "first convergence after a state change applies through the daemon's own plan", %{home: home} do
      Application.put_env(:daemon, :engine_apply, true)

      # The state change: an earlier generation deployed the tmux2k theme and
      # the current catalog declares its removal. The target is on disk AND
      # journal-recorded — the first-convergence window, where the apply-mode
      # composition activates the removal (rebuilding .chezmoiremove, the
      # manifest and the generation) and the pure read-mode plan cannot see it.
      target = ".config/tmux/themes/tmux2k.conf"
      path = Path.join(home, target)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "old theme\n")

      state = Path.join([home | EngineState.state_components()])
      File.mkdir_p!(Path.join(state, "journal"))
      File.chmod!(Path.join(state, "journal"), 0o700)

      # The prior generation's journal record in the shape every reader
      # verifies (the plan wire's baseline check re-verifies the recorded
      # generation directory and derives patches against it): the recorded
      # generation staged exactly the engine's policy tombstone.
      old_generation = String.duplicate("a", 64)
      old_directory = EngineState.generation_directory(state, old_generation)
      File.mkdir_p!(old_directory)

      old_tombstone = Workstation.Core.Policy.remove_file([])
      File.write!(Path.join(old_directory, ".chezmoiremove"), old_tombstone)
      File.chmod!(Path.join(old_directory, ".chezmoiremove"), 0o644)

      old_manifest = [
        %{"name" => ".chezmoiremove", "type" => "file", "mode" => 0o644, "sha256" => Digest.sha256(old_tombstone)}
      ]

      File.write!(Path.join([state, "journal", "applied.json"]),
        Jason.encode!(%{
          "revision" => 1,
          "generation" => old_generation,
          "at" => 1_700_000_000,
          "targets" => %{target => EngineState.target_fingerprint(home, target)},
          "manifest" => old_manifest,
          "source_index" => %{},
          "fragments" => %{}
        })
      )

      # The fake backend mirrors the real chezmoi behavior for this plan: the
      # staged .chezmoiremove names the target, so the apply REMOVES it (the
      # tombstone is consumed), which is what heals the divergence below.
      install_fake_chezmoi(
        home,
        fixture_target(home) <> "\nrm -f '#{path}'\n"
      )

      # The read-mode plan (what `plan.run` serves and what the client used to
      # confirm) is NOT the generation the mutation surface builds: confirming
      # it refuses as stale — the double-collect divergence, pinned.
      read_generation = read_mode_generation(home)

      assert {:error, {"apply_refused", message}} =
               Apply.run(read_generation, home: home, collector: fn -> {:ok, sandbox_catalog(home)} end)

      assert message =~ "stale plan"

      # `apply.plan` serves the composition the daemon executes; the confirmed
      # generation IS the executed one and the first convergence applies.
      assert {:ok, %{"schema" => "workstation.plan.v1", "generation" => generation}} =
               Apply.plan(home: home, collector: fn -> {:ok, sandbox_catalog(home)} end)

      refute generation == read_generation

      assert {:ok, %{"generation" => ^generation}} =
               Apply.run(generation, home: home, collector: fn -> {:ok, sandbox_catalog(home)} end)

      record = applied_record(home)
      assert record["generation"] == generation
      assert record["revision"] == 2

      # The executed generation carried the ACTIVE removal — the divergence's
      # substance, staged exactly as the backend consumed it.
      directory = Path.join([home | EngineState.state_components() ++ ["generations", generation]])
      tombstone = File.read!(Path.join(directory, ".chezmoiremove"))
      assert tombstone =~ target

      # Steady state: the tombstone consumed the target, so the read-mode plan
      # and the mutation plan agree AGAIN — the divergence was the first
      # convergence window, and a fresh confirmation pair re-applies cleanly.
      assert {:ok, %{"schema" => "workstation.plan.v1", "generation" => steady_generation}} =
               Apply.plan(home: home, collector: fn -> {:ok, sandbox_catalog(home)} end)

      refute steady_generation == generation
      assert steady_generation == read_mode_generation(home)

      assert {:ok, %{"generation" => ^steady_generation}} =
               Apply.run(steady_generation, home: home, collector: fn -> {:ok, sandbox_catalog(home)} end)

      assert applied_record(home)["revision"] == 3
    end

    test "over the wire, apply.plan serves the mutation-bound composition and the guard still binds", %{home: home} do
      Application.put_env(:daemon, :engine_apply, true)
      wait_for_file(Listener.socket_path())

      # The live catalog declares the tmux2k removal; present on disk, it
      # activates at the apply-mode boundary — the wire's two plan surfaces
      # structurally diverge exactly as they do on a real first convergence.
      target = ".config/tmux/themes/tmux2k.conf"
      path = Path.join(home, target)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "old theme\n")

      assert %{"ok" => true, "result" => %{"schema" => "workstation.plan.v1", "generation" => generation}} =
               request("apply.plan", %{}, 30_000)

      assert byte_size(generation) == 64

      assert %{"ok" => true, "result" => %{"generation" => read_generation}} = request("plan.run", %{}, 30_000)
      refute generation == read_generation

      # The guard still binds: a client confirming a generation the daemon is
      # not building is refused as stale, whatever served it.
      assert %{"ok" => false, "error" => %{"code" => "apply_refused", "message" => message}} =
               request("apply.run", %{"generation" => read_generation, "entries" => []})

      assert message =~ "stale plan"

      # And the served confirmation composes deterministically: a second
      # apply.plan answers the same generation the execute would build.
      assert %{"ok" => true, "result" => %{"generation" => ^generation}} = request("apply.plan", %{}, 30_000)
    end

    test "with the gate open, a contended apply lock maps to the locked protocol error", %{home: home} do
      Application.put_env(:daemon, :engine_apply, true)

      # Contention is a CROSS-PROCESS fact (a one-shot apply, or another
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

    @tag timeout: 120_000
    test "with the gate open, the update apply step is served, not gated", %{home: home} do
      Application.put_env(:daemon, :engine_apply, true)

      wait_for_file(Listener.socket_path())

      # The wire proof is the CODE — the apply step's own failure code, never
      # the graduation gate and never a transport artifact. The chain must
      # answer, and the answer must be the chain's own `apply_failed`.
      #
      # The failure is seeded at the precondition boundary (an unresolved
      # foreign pending attempt whose target exists on disk but is neither
      # journal-owned nor desired — the recovery law's own guard, raised
      # before any effect runs) so the reply is deterministic. This test
      # previously let the chain walk the FULL real catalog to its honest
      # chezmoi-missing failure; that walk is a function of real-world WAN
      # latency (git pins + ~360MB of archive fetches — 143s on a quiet box
      # the day this flaked), which no fixed frame budget can bound: it was
      # raised 30s -> 120s once already and still red'd 4/10 loaded runs
      # (single CDN transfers stalling >100s mid-flight). The end-to-end
      # backend apply, journal record and ownership paths stay covered by
      # the fixture-catalog tests in this family; what this test pins is the
      # op surface: update.run step=apply composes the LIVE catalog (no
      # collector injection), takes the real apply lock, runs the chain, and
      # reports the chain's failure — with the gate open, `not_graduated`
      # can never be the answer.
      #
      # The frame budget and this test's ExUnit timeout are still a PAIR
      # (request/3 applies the budget to the hello recv and to every drained
      # frame): 30s wire under a 120s ExUnit ceiling leaves 4x margin for a
      # saturated box.
      state = Path.join([home | EngineState.state_components()])
      File.mkdir_p!(Path.join([state, "journal", "pending"]))
      File.chmod!(Path.join(state, "journal"), 0o700)

      File.write!(Path.join([state, "journal", "pending", "ghost-attempt.json"]),
        Jason.encode!(%{"generation" => String.duplicate("b", 64), "targets" => [".config/fixture/ghost"]})
      )

      ghost = Path.join(home, ".config/fixture/ghost")
      File.mkdir_p!(Path.dirname(ghost))
      File.write!(ghost, "ghost\n")

      reply = request("update.run", %{"step" => "apply"}, 30_000)
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

  # The read-mode plan generation — what `plan.run` serves and what the apply
  # client confirmed before `apply.plan` existed. Pure compose: no journal
  # stamp, no removal activation, so a first-convergence home composes a
  # DIFFERENT generation than the mutation surface builds.
  defp read_mode_generation(home) do
    run = Pipeline.run(%Pipeline.Run{input: {:file, fixture_envelope(home)}, mode: :read, home: home}, :compose)
    run.plan.generation
  end

  defp sandbox_catalog(home), do: Catalog.load(fixture_envelope(home))

  # The generation-precheck fixtures: the repo root doubles as the engine
  # anchor (engine_root resolution adopts the checkout's workstation/
  # payload child and build_anchor walks back to mix.exs), and a stale
  # release is a `.built-from` stamp that names no real HEAD.
  defp repo_root, do: Path.expand("../../../../..", __DIR__)

  defp stamp_stale_release!(home) do
    stamp = Path.join([home, ".local", "opt", "workstation", ".built-from"])
    File.mkdir_p!(Path.dirname(stamp))
    File.write!(stamp, "0000000000000000000000000000000000000000\n")
  end

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
            # A declared removal of a target an earlier generation deployed:
            # inactive while the target is absent, ACTIVE (journal-recorded or
            # home-present) at the apply-mode boundary — the first-convergence
            # divergence between the read-mode plan and the mutation plan.
            %{
              "provider" => "chezmoi",
              "spec" => %{"kind" => "remove", "target" => ".config/tmux/themes/tmux2k.conf"}
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

  defp request(op, params, timeout \\ 2_000) do
    {:ok, sock} = :socket.open(:local, :stream, :default)

    try do
      :ok = :socket.connect(sock, %{family: :local, path: String.to_charlist(Listener.socket_path())}, 2_000)
      :ok = :socket.send(sock, Protocol.encode_frame(hello_body()))
      {:ok, _hello_frame} = recv_frame(sock, timeout)

      :ok = :socket.send(sock, Protocol.encode_frame(Jason.encode!(%{"v" => 1, "id" => "l1", "op" => op, "params" => params})))
      # Ops stream progress events ahead of the reply now (the daemon owns
      # the chain); drain the event frames until the id-matched result.
      recv_result(sock, "l1", timeout)
    after
      :socket.close(sock)
    end
  end

  defp hello_body,
    do: Jason.encode!(%{"v" => 1, "id" => "h1", "op" => "hello", "params" => %{"protocol" => Protocol.protocol_name()}})

  defp recv_result(sock, id, timeout) do
    case recv_frame(sock, timeout) do
      {:ok, %{"id" => ^id} = reply} -> reply
      {:ok, %{"event" => _event}} -> recv_result(sock, id, timeout)
      {:ok, other} -> flunk("unexpected frame: " <> inspect(other))
    end
  end

  defp recv_frame(sock, timeout) do
    {:ok, <<length::unsigned-big-integer-size(32)>>} = :socket.recv(sock, 4, timeout)
    {:ok, body} = recv_exact(sock, length, timeout, [])
    {:ok, Jason.decode!(body)}
  end

  defp recv_exact(_sock, 0, _timeout, chunks), do: {:ok, IO.iodata_to_binary(Enum.reverse(chunks))}

  defp recv_exact(sock, remaining, timeout, chunks) do
    {:ok, data} = :socket.recv(sock, remaining, timeout)
    recv_exact(sock, remaining - byte_size(data), timeout, [data | chunks])
  end
end
