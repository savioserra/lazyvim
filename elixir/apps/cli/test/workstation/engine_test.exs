defmodule Workstation.CLITest.EngineTest do
  @moduledoc """
  The CLI engine's update-step plumbing. The apply step closure must accept
  the opts `guarded/3` passes it — the live update chain crashed with a
  BadArityError exactly there ([2/5] bootstrap ok, then the apply step died
  before the engine ran), so this suite runs the crashed path headless in a
  WORKSTATION_HOME-bracketed sandbox home and pins the step to succeed,
  journal, and stay idempotent.
  """

  use ExUnit.Case, async: false

  alias Workstation.CLI.Engine
  alias Workstation.Core.{Catalog, Digest, EngineState, Journal}

  setup do
    {_root, home} = temp_test_root()
    previous = System.get_env("WORKSTATION_HOME")
    # The incident-hardening rule: a mutating run must never resolve engine
    # state from the real $HOME. The bracket pins the whole engine state
    # (journal reads anchor on the global WORKSTATION_HOME tree; journal
    # writes anchor on the destination) to the sandbox — the daemon-test
    # pattern, where destination and bracket are the same sandbox tree.
    System.put_env("WORKSTATION_HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")
    end)

    %{home: home}
  end

  test "the update chain's apply step executes through the guarded closure without BadArity", %{home: home} do
    generation = fixture_plan_generation(home)
    install_fake_chezmoi(home, fixture_target(home))

    # The exact wiring the plain update runner drives: run_update folds the
    # step names through the update executor into Engine.run_step/2 — the
    # pre-fix closure crashed HERE with BadArityError (0-arity fun, one
    # opts argument), after pull and bootstrap had already succeeded.
    assert {:ok, %{"step" => "apply", "status" => "ok", "generation" => ^generation}} =
             Engine.run_step("apply", home: home, collector: fn -> {:ok, sandbox_catalog(home)} end)

    # The step journaled into the BRACKETED state root, under its own
    # generation, with the backend's fingerprint on the deployed file.
    # The journal record is written home-ARG-anchored (the destination
    # tree), while the guarded Journal.applied read verifies the GLOBAL
    # WORKSTATION_HOME tree — this suite keeps those two DELIBERATELY split
    # (incident convention), so assert on the destination-anchored file
    # directly: the step must journal next to the home it mutated, never
    # fall back to the ambient environment.
    record = Journal.applied(Path.join([home | EngineState.state_components()]))
    assert record["revision"] == 1
    assert record["generation"] == generation
    assert record["targets"][".config/fixture/rc"]["sha256"] == Digest.sha256("export FIXTURE=1\n")

    # And the step is re-runnable: the update chain must be able to advance
    # past apply again on an identical desired generation (idempotent no-op,
    # revision advances).
    assert {:ok, %{"step" => "apply", "status" => "ok", "generation" => ^generation}} =
             Engine.run_step("apply", home: home, collector: fn -> {:ok, sandbox_catalog(home)} end)

    assert Journal.applied(Path.join([home | EngineState.state_components()]))["revision"] == 2
  end

  ## release refresh + handoff note (the update chain's engine-refresh contract)

  # The repo root doubles as the engine anchor: it holds the elixir/ umbrella
  # directly, so opts[:engine_root] = repo_root() pins every resolution.
  defp repo_root, do: Path.expand("../../../../..", __DIR__)

  # Mirrors the engine's config-isolated rev-parse exactly: the staleness
  # comparison is stamp vs THIS value.
  defp repo_head do
    {out, 0} =
      System.cmd("git", ["-C", repo_root(), "rev-parse", "HEAD"],
        stderr_to_stdout: true,
        env: [{"GIT_CONFIG_NOSYSTEM", "1"}, {"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_SYSTEM", "/dev/null"}]
      )

    String.trim_trailing(out)
  end

  defp stamp_path(home), do: Path.join([home, ".local", "opt", "workstation", ".built-from"])

  defp note_path(home), do: Path.join([home | EngineState.state_components()] ++ ["update", "handoff.json"])

  # The production installer contract, faked: record the invocation, stage
  # the activated release's HEAD stamp. A refresh test that needs a
  # never-call installer passes a flunking closure instead.
  defp spy_install do
    {:ok, pid} = Agent.start_link(fn -> [] end)

    fun = fn anchor, home ->
      Agent.update(pid, &[{anchor, home} | &1])
      File.mkdir_p!(Path.dirname(stamp_path(home)))
      File.write!(stamp_path(home), repo_head() <> "\n")
      {"installed\n", 0}
    end

    {pid, fun}
  end

  defp spy_calls(pid), do: Agent.get(pid, &Enum.reverse/1)

  defp bootstrap_stub, do: fn _opts -> {:ok, %{"step" => "bootstrap", "status" => "ok"}} end

  test "release refresh skips honestly without a buildable anchor", %{home: home} do
    # A valid ENGINE checkout (the launcher's three anchor files) that does
    # not ship the elixir/ umbrella — laid out as <tmp>/workstation so the
    # engine's anchor resolution evaluates this tree and finds no release
    # source: engine_root accepts it, and the honest answer is a skip.
    parent = Path.join(System.tmp_dir!(), "ws-anchorless-#{System.unique_integer([:positive])}")
    anchorless = Path.join(parent, "workstation")
    File.mkdir_p!(Path.join([anchorless, "bin"]))
    File.mkdir_p!(Path.join([anchorless, "bootstrap"]))

    File.cp!(Path.join([repo_root(), "workstation", "bootstrap", "bootstrap.pins"]), Path.join([anchorless, "bootstrap", "bootstrap.pins"]))
    File.cp!(Path.join([repo_root(), "workstation", "versions.json"]), Path.join([anchorless, "versions.json"]))

    File.cp!(Path.join([repo_root(), "workstation", "bin", "workstation"]), Path.join([anchorless, "bin", "workstation"]))

    on_exit(fn -> File.rm_rf!(parent) end)

    {spy, installer} = spy_install()

    assert {:ok, false} = Engine.release_refresh(engine_root: anchorless, home: home, installer: installer)
    assert spy_calls(spy) == []
  end

  test "a stale release refreshes through the installer and a stamped release then skips", %{home: home} do
    {spy, installer} = spy_install()

    assert {:ok, true} = Engine.release_refresh(engine_root: repo_root(), home: home, installer: installer)
    assert spy_calls(spy) == [{repo_root(), home}]

    # The installer's stamp names the source HEAD it built; the next
    # refresh against the same checkout is a no-op (this is what makes the
    # update handoff terminate).
    assert {:ok, false} =
             Engine.release_refresh(engine_root: repo_root(), home: home,
               installer: fn _a, _h -> flunk("installer must not run when the stamp matches HEAD") end
             )
  end

  test "a failed installer aborts the refresh with its output", %{home: home} do
    assert {:error, "boom"} =
             Engine.release_refresh(engine_root: repo_root(), home: home,
               installer: fn _a, _h -> {"boom\n", 1} end
             )
  end

  test "the bootstrap step records the refresh and leaves a handoff note for its own release", %{home: home} do
    {_spy, installer} = spy_install()

    assert {:ok, record} =
             Engine.run_step("bootstrap",
               home: home,
               engine_root: repo_root(),
               bootstrap_run: bootstrap_stub(),
               installer: installer
             )

    assert record["release_refreshed"] == true

    assert {:ok, %{"from_release" => release}} =
             note_path(home)
             |> File.read!()
             |> Jason.decode()

    assert release == :code.root_dir() |> to_string()

    # Probing under the release that wrote the note hands off — and the
    # note SURVIVES the handoff decision, so a crashed re-exec re-derives
    # the same handoff on the next run instead of finishing under stale
    # code.
    assert {:ok, ^release} = Engine.update_handoff(home: home)
    assert File.exists?(note_path(home))
  end

  test "a refresh-free bootstrap clears a leftover handoff note and never calls the installer", %{home: home} do
    File.mkdir_p!(Path.dirname(stamp_path(home)))
    File.write!(stamp_path(home), repo_head() <> "\n")
    File.mkdir_p!(Path.dirname(note_path(home)))
    File.write!(note_path(home), Jason.encode!(%{"from_release" => "/opt/some-release"}))

    assert {:ok, record} =
             Engine.run_step("bootstrap",
               home: home,
               engine_root: repo_root(),
               bootstrap_run: bootstrap_stub(),
               installer: fn _a, _h -> flunk("installer must not run when the stamp matches HEAD") end
             )

    assert record["release_refreshed"] == false
    refute File.exists?(note_path(home))
  end

  test "a note naming a different (newer) release is consumed with no handoff", %{home: home} do
    File.mkdir_p!(Path.dirname(note_path(home)))
    File.write!(note_path(home), Jason.encode!(%{"from_release" => "/opt/fake-release"}))

    assert {:ok, nil} = Engine.update_handoff(home: home)
    refute File.exists?(note_path(home))
  end

  test "a malformed handoff note is an error, never a silent continue", %{home: home} do
    File.mkdir_p!(Path.dirname(note_path(home)))
    File.write!(note_path(home), "not json")

    assert {:error, message} = Engine.update_handoff(home: home)
    assert message =~ "malformed release handoff note"
  end

  ## sandbox plumbing (mirrors the daemon apply suite's fixtures)

  defp temp_test_root do
    root = Path.join(System.tmp_dir!(), "ws-cli-engine-#{System.unique_integer([:positive])}")
    home = Path.join(root, "home")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(root) end)
    {root, home}
  end

  defp sandbox_catalog(home), do: Catalog.load(fixture_envelope(home))

  defp fixture_envelope(home) do
    %{
      "profile" => "cli-engine-sandbox",
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

  # The provisioner resolves managed tools under the STATE ROOT (the
  # workstation state bracket). This suite pins the bracket to the sandbox
  # home (daemon-test pattern), so the fake backend installs there.
  defp install_fake_chezmoi(state_root, instructions) do
    bin = Path.join([state_root, ".local", "opt", "chezmoi", "bin", "chezmoi"])
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

  defp fixture_plan_generation(home) do
    catalog = sandbox_catalog(home)
    graph = Workstation.Core.Graph.order(%{host: catalog.host, specifications: catalog.packages})

    %Workstation.Core.Source{generation: generation} =
      Workstation.Core.Source.plan(%{graph: graph})

    generation
  end
end
