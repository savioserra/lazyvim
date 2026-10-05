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
