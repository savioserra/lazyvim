defmodule Workstation.Daemon.LifecycleChainTest do
  @moduledoc """
  The update-chain step semantics over the REAL socket and at module level
  (module level is where sandbox injection needs it): the read-only steps
  serve real reconciliation/verification and fail honestly on an empty
  home, contention on a MUTATING step reports the recorded lock owner, and
  the apply step delegates to the daemon applier under the caller's lock.

  The chain is deliberately never graduation-gated (bootstrap provisions
  the release, pre-graduation included); the apply-pipeline flag is pinned
  in the apply/lifecycle suites. This suite was the Daemon.Update suite —
  the orchestrator merged into `Workstation.Daemon.Lifecycle` when the
  daemon became the only mutation engine (engine work, M1).
  """

  use ExUnit.Case, async: false

  alias Workstation.Core.{Catalog, Digest, EngineState, Graph, Journal, Source}
  alias Workstation.Daemon.{ApplyOrchestrator, Lifecycle, Listener, Protocol}

  setup do
    home = Path.join(System.tmp_dir!(), "c2-daemon-update-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")
      Application.delete_env(:daemon, :engine_apply)
      File.rm_rf!(home)
    end)

    start_supervised!(Workstation.Daemon.Application.supervisor_spec())
    wait_for_file(Listener.socket_path())

    %{home: home}
  end

  describe "the chain steps" do
    test "serve the read-only steps, which fail honestly on an empty home" do
      for step <- ["sync", "verify"] do
        reply = request("update.run", %{"step" => step})

        # The step EXECUTED (nothing applied to reconcile/verify in a fresh
        # sandbox) and the lock is released once it answers.
        assert %{"ok" => false, "error" => %{"code" => "update_failed", "message" => message}} = reply
        assert message =~ "no applied generation"
      end

      refute File.exists?(ApplyOrchestrator.lock_path(EngineState.state_root()))
    end

    test "a held lock reports its owner instead of running the mutating step" do
      {:ok, token, _path} = ApplyOrchestrator.acquire("held by test")

      reply = request("update.run", %{"step" => "apply"})

      assert %{"ok" => false, "error" => %{"code" => "locked", "message" => message}} = reply
      assert message =~ "apply lock held by uid="

      :ok = ApplyOrchestrator.release(token)
    end

    test "the served verify step reports per-package status over the wire", %{home: home} do
      publish_launcher!(home)
      seed_targets!(home, %{"fixture" => [{".config/fixture/rc", "export FIXTURE=1\n"}]})

      reply = request("update.run", %{"step" => "verify"})

      assert %{"ok" => true, "result" => %{"step" => "verify", "status" => "ok", "packages" => packages}} = reply
      assert [%{"package" => "fixture", "targets" => 1, "status" => "ok", "drifted" => []}] = packages
    end
  end

  describe "the apply step at module level" do
    test "delegates to the daemon applier under the caller's lock", %{home: home} do
      generation = fixture_plan_generation(home)
      install_fake_chezmoi(home, fixture_target(home))

      assert {:ok, %{"generation" => ^generation}} =
               Lifecycle.run_step("apply", home: home, collector: fn -> {:ok, sandbox_catalog(home)} end)

      record = applied_record(home)
      assert record["generation"] == generation

      # The orchestration serialized through the SAME lock; it is released.
      refute File.exists?(ApplyOrchestrator.lock_path(EngineState.state_root()))
    end
  end

  ## socket plumbing (same contract as the lifecycle suite)

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

  defp wait_for_file(path, tries \\ 100)

  defp wait_for_file(_path, 0), do: flunk("listener socket never appeared")

  defp wait_for_file(path, tries) do
    if File.exists?(path), do: :ok, else: (Process.sleep(20) && wait_for_file(path, tries - 1))
  end

  ## fixtures (mirrors of the c1 suite's sandbox apply fixtures)

  defp fixture_plan_generation(home) do
    catalog = Catalog.load(fixture_envelope(home))
    graph = Graph.order(%{host: catalog.host, specifications: catalog.packages})
    %Source{generation: generation} = Source.plan(%{graph: graph})
    generation
  end

  defp sandbox_catalog(home), do: Catalog.load(fixture_envelope(home))

  defp fixture_envelope(home) do
    %{
      "profile" => "daemon-update-sandbox",
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

  defp applied_record(home) do
    home
    |> then(fn home -> Path.join([home | EngineState.state_components()] ++ ["journal", "applied.json"]) end)
    |> File.read!()
    |> Jason.decode!()
  end

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

    """
    mkdir -p '#{Path.dirname(destination)}'
    printf '%s' '#{"export FIXTURE=1\n"}' > '#{destination}'
    chmod 644 '#{destination}'
    """
  end

  defp publish_launcher!(home) do
    # The daemon serves the REAL engine checkout in tests, so the canonical
    # launcher symlink must point at its realpath for verify to pass. The
    # root is pinned EXPLICITLY (repo-root-derived) so sandbox suites that
    # legitimately perturb engine-checkout resolution can never redirect
    # this fixture.
    root =
      Path.expand("../../../../../../", __DIR__)
      |> Path.join("workstation")

    target = Workstation.Core.Update.realpath(Path.join(root, "bin/workstation"))
    launcher = Path.join([home, ".local", "bin", "workstation"])
    File.mkdir_p!(Path.dirname(launcher))
    File.ln_s!(target, launcher)
    launcher
  end

  defp seed_targets!(home, packages) do
    targets =
      for {owner, entries} <- packages, {target, contents} <- entries do
        path = EngineState.join_home(home, target)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, contents)
        fingerprint = EngineState.target_fingerprint(home, target)

        {target,
         fingerprint
         |> Map.put("owner", owner)
         |> Map.put("operation", "create")}
      end

    :ok = EngineState.ensure_roots!(home)
    :ok = Journal.record_applied(home, Digest.sha256("fixture-generation"), Map.new(targets), [], [], %{})
    :ok
  end
end
