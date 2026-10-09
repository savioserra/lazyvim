defmodule Workstation.Core.PlanTest do
  @moduledoc """
  The composition-boundary contract for declared removals: `Source.plan/1`
  composes every declared removal inert (replay purity — a golden records a
  fresh journal and no filesystem), and `Pipeline.composed_plan/2` is the
  one production surface that activates them, exactly when the journal
  recorded the target or the target is present in the destination home. The
  tmux2k cutover tombstone is the first real consumer: without this
  boundary the declared removal was validated-but-inert on every surface.
  """

  use ExUnit.Case, async: false

  alias Workstation.Core.{Graph, Pipeline, Policy, Source}
  alias Workstation.Core.Catalog
  alias Workstation.Core.Catalog.Packages

  setup context do
    home = Path.join(System.tmp_dir!(), "workstation-plan-#{context.test}-#{:os.getpid()}")
    File.rm_rf!(home)
    File.mkdir_p!(home)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")
      File.rm_rf!(home)
    end)

    %{home: home}
  end

  describe "composed_plan/2 declared-removal activation" do
    test "a declared removal activates when the journal recorded the target", %{home: home} do
      owner = package("retired", [file_recipe(".config/tooling/rc", "export A=1\n")])
      {:ok, first} = Pipeline.composed_plan(home, collect([owner]))

      # First apply records the target in the journal's applied record.
      install_fake_chezmoi(home, deploy_instructions(home, first))
      assert Pipeline.execute(first, %{"home" => home}) == first.generation

      # The same target, now declared as a tombstone: the boundary activates
      # it from the journal record, rebuilds .chezmoiremove and the
      # generation id — a real mutation, never an idempotent no-op.
      remover = package("retired", [removal_recipe(".config/tooling/rc")])
      {:ok, plan} = Pipeline.composed_plan(home, collect([remover]))

      assert plan.removals == [%{target: ".config/tooling/rc", owner: "retired"}]
      assert plan.remove_file == Policy.remove_file([".config/tooling/rc"])
      assert plan.remove_file =~ ~r/\n\.config\/tooling\/rc\n/
      assert plan.generation != first.generation
      assert plan.journal_revision == 1

      # The pure plan for the same graph stays inert: the golden contract.
      pure = Source.plan(%{graph: graph([remover])})
      assert pure.removals == []
      assert pure.generation != plan.generation
    end

    test "a declared removal activates when the target is present in the destination home", %{home: home} do
      # Unjournaled home, but the stale bytes are on disk — a regular file
      # and a stale (broken) symlink both mark their target present.
      File.mkdir_p!(Path.join(home, ".config/tooling"))
      File.write!(Path.join(home, ".config/tooling/rc"), "stale\n")
      File.mkdir_p!(Path.join(home, ".config/app"))
      # The pinned build lacks File.symlink/1-2 — make the stale link via Erlang.
      :ok = :file.make_symlink(Path.join(home, "nowhere"), Path.join(home, ".config/app/legacy"))

      remover =
        package("retired", [
          removal_recipe(".config/tooling/rc"),
          removal_recipe(".config/app/legacy")
        ])

      {:ok, plan} = Pipeline.composed_plan(home, collect([remover]))

      assert plan.removals == [
               %{target: ".config/tooling/rc", owner: "retired"},
               %{target: ".config/app/legacy", owner: "retired"}
             ]

      assert plan.remove_file == Policy.remove_file([".config/tooling/rc", ".config/app/legacy"])
    end

    test "a declared removal stays inactive with no journal record and no target on disk", %{home: home} do
      remover = package("retired", [removal_recipe(".config/tooling/rc")])
      {:ok, plan} = Pipeline.composed_plan(home, collect([remover]))

      assert plan.removals == []
      assert plan.remove_file == Policy.remove_file([])

      # Inactive means byte-stable: the composed generation equals the pure
      # plan's, so a no-tombstone home never leaves its recorded generation.
      pure = Source.plan(%{graph: graph([remover])})
      assert plan.generation == pure.generation
      assert plan.manifest == pure.manifest
    end

    test "the tmux2k tombstone activates through the live catalog on a present target", %{home: home} do
      # The real cutover: the live native catalog declares exactly one
      # removal, and a home still carrying the retired theme file gets it
      # tombstoned at the composition boundary.
      File.mkdir_p!(Path.join(home, ".config/tmux/themes"))
      File.write!(Path.join(home, ".config/tmux/themes/tmux2k.conf"), "# retired theme\n")

      {:ok, plan} = Pipeline.composed_plan(home)

      assert plan.removals == [%{target: ".config/tmux/themes/tmux2k.conf", owner: "tmux"}]
      assert plan.remove_file == Policy.remove_file([".config/tmux/themes/tmux2k.conf"])

      # Without the target on disk the same composition stays inert.
      File.rm!(Path.join(home, ".config/tmux/themes/tmux2k.conf"))
      {:ok, inert} = Pipeline.composed_plan(home)
      assert inert.removals == []
      assert inert.generation != plan.generation
    end
  end

  # --- fixtures ---

  defp collect(packages), do: fn -> {:ok, catalog(packages)} end

  defp catalog(packages) do
    %Catalog{profile: "test", host: "linux", home: "/home/test", packages: packages, assets: %{}}
  end

  defp package(id, contributes) do
    %{id: id, requires: [], supported_hosts: nil, contributes: contributes}
  end

  defp graph(packages), do: Graph.order(%{host: "linux", specifications: packages})

  defp file_recipe(target, content), do: Packages.chezmoi(target: target, kind: :file, content: content)
  defp removal_recipe(target), do: Packages.chezmoi(target: target, kind: :remove)

  # A pinned fake backend: it appends its exact argv to `<bin>.argv` and runs
  # the per-test instruction script that produces the plan's targets (what
  # the real backend would deploy).
  defp install_fake_chezmoi(home, instructions) do
    bin = Path.join([home, ".local", "opt", "chezmoi", "bin", "chezmoi"])
    File.mkdir_p!(Path.dirname(bin))

    File.write!(bin <> ".instructions", instructions)
    File.write!(bin, "#!/bin/sh\nfor arg in \"$@\"; do printf '%s\\n' \"$arg\" >> \"#{bin}.argv\"; done\nsh \"#{bin}.instructions\"\n")
    File.chmod!(bin, 0o755)
    bin
  end

  defp deploy_instructions(home, plan) do
    Enum.map_join(plan.entries, "\n", fn entry ->
      destination = Path.join(home, entry.target)
      body = String.replace(entry.bytes, "'", "'\\''")

      """
      mkdir -p '#{Path.dirname(destination)}'
      printf '%s' '#{body}' > '#{destination}'
      chmod #{Integer.to_string(entry.mode, 8)} '#{destination}'
      """
    end)
  end
end
