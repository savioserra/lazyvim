defmodule Workstation.Daemon.UpdateTest do
  @moduledoc """
  The daemon's update orchestrator over the REAL socket (and at module level
  where sandbox injection needs it): the graduation gate still answers
  `not_graduated` for the MUTATION steps while it is closed, the read-only
  steps serve real reconciliation/verification against the sandbox home,
  contention reports the recorded lock owner, and with the gate open the
  apply step delegates to the c1 executor under the caller's lock.
  """

  use ExUnit.Case, async: false

  alias Workstation.Core.{Catalog, Digest, EngineState, Graph, Journal, Source}
  alias Workstation.Daemon.{ApplyOrchestrator, Listener, Protocol, Update}

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

  describe "the graduation gate" do
    test "gates the mutation steps off with the honest refusal, lock released" do
      for step <- Update.steps() |> Enum.filter(&Update.mutation_step?/1) do
        reply = request("update.run", %{"step" => step})

        assert %{"ok" => false, "error" => %{"code" => "not_graduated", "message" => message}} = reply
        assert message == Workstation.Daemon.Apply.not_graduated_message()
      end

      refute File.exists?(ApplyOrchestrator.lock_path(EngineState.state_root()))
    end

    test "serves the read-only steps, which fail honestly on an empty home" do
      for step <- ["sync", "verify"] do
        reply = request("update.run", %{"step" => step})

        # The code differs from the gate refusal: the step EXECUTED (nothing
        # applied to reconcile/verify in a fresh sandbox) and the lock is
        # released once it answers.
        assert %{"ok" => false, "error" => %{"code" => "update_failed", "message" => message}} = reply
        assert message =~ "no applied generation"
      end

      refute File.exists?(ApplyOrchestrator.lock_path(EngineState.state_root()))
    end

    test "a held lock reports its owner instead of running the step" do
      {:ok, token, _path} = ApplyOrchestrator.acquire("held by test")

      reply = request("update.run", %{"step" => "verify"})

      assert %{"ok" => false, "error" => %{"code" => "locked", "message" => message}} = reply
      assert message =~ "apply lock held by uid="

      :ok = ApplyOrchestrator.release(token)
    end

    test "with the gate open the read-only step no longer answers the gate" do
      Application.put_env(:daemon, :engine_apply, true)

      reply = request("update.run", %{"step" => "verify"})

      # The step executes (and honestly fails on the empty sandbox) — the
      # wire proof that the gate no longer intercepts it.
      assert %{"ok" => false, "error" => %{"code" => "update_failed"}} = reply
    end
  end

  describe "with the gate open" do
    test "the apply step delegates to the c1 executor under the caller's lock", %{home: home} do
      Application.put_env(:daemon, :engine_apply, true)
      generation = fixture_plan_generation(home)
      install_fake_chezmoi(home, fixture_target(home))

      assert {:ok, %{"generation" => ^generation}} =
               Update.run("apply", home: home, collector: fn -> {:ok, sandbox_catalog(home)} end)

      record = applied_record(home)
      assert record["generation"] == generation

      # The orchestration serialized through the SAME lock; it is released.
      refute File.exists?(ApplyOrchestrator.lock_path(EngineState.state_root()))
    end

    test "the mutation steps answer the same gate when the flag is off" do
      Application.delete_env(:daemon, :engine_apply)

      # Module-level gate checks run BEFORE any step body: pull never
      # touches git and bootstrap never touches the network here.
      for step <- ["pull", "bootstrap", "apply"] do
        assert {:error, {"not_graduated", _message}} = Update.run(step)
      end
    end

    test "the served verify step reports per-package status over the wire", %{home: home} do
      Application.put_env(:daemon, :engine_apply, true)
      publish_launcher!(home)
      seed_targets!(home, %{"fixture" => [{".config/fixture/rc", "export FIXTURE=1\n"}]})

      reply = request("update.run", %{"step" => "verify"})

      assert %{"ok" => true, "result" => %{"step" => "verify", "status" => "ok", "packages" => packages}} = reply
      assert [%{"package" => "fixture", "targets" => 1, "status" => "ok", "drifted" => []}] = packages
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
      {:ok, frame} = recv_frame(sock)
      Jason.decode!(frame)
    after
      :socket.close(sock)
    end
  end

  defp hello_body,
    do: Jason.encode!(%{"v" => 1, "id" => "h1", "op" => "hello", "params" => %{"protocol" => Protocol.protocol_name()}})

  defp recv_frame(sock) do
    {:ok, <<length::unsigned-big-integer-size(32)>>} = :socket.recv(sock, 4, 2_000)
    recv_exact(sock, length, [])
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
