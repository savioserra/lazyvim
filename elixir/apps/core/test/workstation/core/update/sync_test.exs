defmodule Workstation.Core.Update.SyncTest do
  @moduledoc """
  The sync step: re-collect + plan reconciliation against the journal, over
  an injected sandbox catalog (no filesystem reads beyond the journal). The
  divergence case is the point: a fresh plan whose generation no longer
  matches the applied one must abort the update, never be waved through.
  """

  use ExUnit.Case, async: false

  alias Workstation.Core.Update.Sync
  alias Workstation.Core.{Catalog, EngineState, Graph, Journal, Source}

  setup do
    home = Path.join(System.tmp_dir!(), "c2-sync-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")
      File.rm_rf!(home)
    end)

    %{home: home}
  end

  test "reconciles when the fresh plan matches the applied generation", %{home: home} do
    generation = seed_applied!(home, fixture_envelope(home))

    assert {:ok,
            %{
              "step" => "sync",
              "status" => "ok",
              "generation" => ^generation,
              "revision" => 1
            }} = Sync.run(home: home, collector: collector_for(home))
  end

  test "refuses to reconcile when nothing was ever applied", %{home: home} do
    assert_raise ArgumentError, ~r/no applied generation to reconcile/, fn ->
      Sync.run(home: home, collector: collector_for(home))
    end
  end

  test "fails when the fresh plan generation diverges from the journal", %{home: home} do
    seed_applied!(home, fixture_envelope(home))

    # A structural source change (a different target) changes the plan's
    # generation: sync must catch the drift between live source and journal.
    diverged =
      put_in(fixture_envelope(home), ["packages"], [
        %{
          "id" => "fixture",
          "requires" => [],
          "contributes" => [
            %{
              "provider" => "chezmoi",
              "spec" => %{"asset" => "fixture:files/rc", "kind" => "file", "target" => ".config/other/rc"}
            }
          ]
        }
      ])

    assert_raise ArgumentError, ~r/reconciliation failed.*re-run apply/, fn ->
      Sync.run(home: home, collector: fn -> {:ok, Catalog.load(diverged)} end)
    end
  end

  test "surfaces collector failure as a step failure, never a crash", %{home: home} do
    seed_applied!(home, fixture_envelope(home))

    assert_raise ArgumentError, ~r/plan collection failed/, fn ->
      Sync.run(home: home, collector: fn -> {:error, :sandbox_failure} end)
    end
  end

  ## fixtures

  # The server-side plan composition, used here only to derive the expected
  # generation for the seeded journal (the same pipeline the step runs).
  defp seed_applied!(home, envelope) do
    catalog = Catalog.load(envelope)
    graph = Graph.order(%{host: catalog.host, specifications: catalog.packages})
    %Source{generation: generation} = Source.plan(%{graph: graph})

    :ok = EngineState.ensure_roots!(home)

    :ok =
      Journal.record_applied(home, generation, %{}, [], [], %{
        "fixture" => %{"target" => ".config/fixture/rc", "owner" => "fixture"}
      })

    generation
  end

  defp collector_for(home), do: fn -> {:ok, Catalog.load(fixture_envelope(home))} end

  defp fixture_envelope(home) do
    %{
      "profile" => "sync-sandbox",
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
            }
          ]
        }
      ]
    }
  end
end
