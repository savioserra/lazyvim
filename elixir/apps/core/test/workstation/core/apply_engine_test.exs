defmodule Workstation.Core.ApplyEngineTest do
  @moduledoc """
  Full apply cycles against isolated sandbox homes: staged-tree bytes, the
  real backend argv, journal records in the anchor's schema, idempotent
  re-apply, and every failure anchor (backend failure with its failed-record
  + surviving pending anchor, post-apply generation damage, mismatched
  requested generation). The backend is exercised two ways: through a fake
  pinned `chezmoi` whose argv and produced targets are asserted exactly, and
  through the real `chezmoi` binary when it is on PATH.
  """

  use ExUnit.Case, async: false

  alias Workstation.Core.{ApplyEngine, Digest, EngineState, Journal, Policy, Provisioner, Source}
  alias Workstation.Core.Source.Manifest

  setup context do
    home = Path.join(System.tmp_dir!(), "workstation-apply-engine-#{context.test}-#{:os.getpid()}")
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

  describe "execute/2 full cycles" do
    test "publishes the staged tree, runs the pinned argv, and records the applied journal", %{home: home} do
      plan = build_plan(extra_entries: [executable_entry()], data: "profile = \"apply-sandbox\"\n")
      log = install_fake_chezmoi(home, deploy_instructions(home, plan))

      generation = ApplyEngine.execute(plan, %{"home" => home})

      assert generation == plan.generation

      # The staged generation directory is byte-exact against the plan.
      directory = Path.join([home | EngineState.state_components() ++ ["generations", plan.generation]])
      assert File.dir?(directory)

      # The published generation directory keeps its private staging mode:
      # 0700 pinned at allocation, independent of the process umask.
      assert %File.Stat{mode: generation_mode} = File.stat!(directory)
      assert Bitwise.band(generation_mode, 0o777) == 0o700
      assert File.read!(Path.join(directory, ".chezmoiremove")) == plan.remove_file
      assert File.read!(Path.join(directory, ".chezmoidata.toml")) == "profile = \"apply-sandbox\"\n"
      assert File.read!(Path.join(directory, "dot_config/tooling/rc")) == "export A=1\n"
      assert File.read!(Path.join(directory, "dot_local/bin/tool")) == "#!/bin/sh\necho tool\n"

      # Source files stage at the manifest's pinned 0644 (source.lua: the
      # source path is chezmoi's INPUT; target modes belong to the backend's
      # entry semantics), and the executable target still carries its entry
      # mode in the plan, not in the generation.
      assert %File.Stat{mode: mode} = File.stat!(Path.join(directory, "dot_local/bin/tool"))
      assert Bitwise.band(mode, 0o777) == 0o644
      assert Provisioner.verify_generation(directory, plan.manifest)

      # No staging residue: the staging directory was renamed, not copied.
      generations_root = Path.join([home | EngineState.state_components() ++ ["generations"]])
      assert File.ls!(generations_root) == [plan.generation]

      # The backend ran once, with the exact documented argv (one element
      # per line, so homes with spaces in their names stay parseable).
      argv = File.read!(log <> ".argv") |> String.split("\n", trim: true)
      assert argv == ["--source", directory, "--destination", home, "apply", "--exclude", "scripts"]

      # The applied record carries the anchor's schema, field for field.
      record = Journal.applied(Path.join([home | EngineState.state_components()]))

      assert %{
               "generation" => ^generation,
               "revision" => 1,
               "at" => at,
               "targets" => targets,
               # Journal records are object-faithful (CanonicalJSON
               # encode_record/1): an empty fragments journal is {} — the
               # golden-pinned vim.json empty-table quirk poisoned the real
               # journal once and every reader demands map shapes.
               "fragments" => %{},
               "manifest" => manifest,
               "source_index" => source_index
             } = record

      assert is_integer(at) and at > 0
      assert manifest == plan.manifest

      assert targets == %{
               ".config/tooling/rc" =>
                 Map.merge(%{"type" => "file", "mode" => 0o644, "sha256" => Digest.sha256("export A=1\n")}, %{
                   "owner" => "tooling",
                   "operation" => "create",
                   "source_fingerprint" => "srcfp-rc"
                 }),
               ".local/bin/tool" =>
                 Map.merge(%{"type" => "file", "mode" => 0o755, "sha256" => Digest.sha256("#!/bin/sh\necho tool\n")}, %{
                   "owner" => "tooling",
                   "operation" => "create",
                   "source_fingerprint" => "srcfp-tool",
                   "shared" => true
                 })
             }

      assert source_index == %{
               "dot_config/tooling/rc" => %{
                 "target" => ".config/tooling/rc",
                 "owner" => "tooling",
                 "attribution" => ["tooling"],
                 "type" => "file",
                 "mode" => 0o644
               },
               "dot_local/bin/tool" => %{
                 "target" => ".local/bin/tool",
                 "owner" => "tooling",
                 "attribution" => ["tooling"],
                 "type" => "file",
                 "mode" => 0o755
               }
             }

      # The pending attempt record was cleared after the success.
      assert Journal.pending(Path.join([home | EngineState.state_components()])) == []
    end

    test "an empty catalog plan records an object-shaped journal and a second apply succeeds", %{home: home} do
      # The 2026-10-05 incident: an empty plan once recorded targets and
      # source_index as JSON arrays, and every later reader bricked on the
      # list shape. The writer must always record objects ({} when empty)
      # and the re-apply must stay a success.
      plan = build_plan(entries: [])
      install_fake_chezmoi(home, [])

      assert ApplyEngine.execute(plan, %{"home" => home}) == plan.generation

      state_root = Path.join([home | EngineState.state_components()])
      path = Path.join([state_root, "journal", "applied.json"])
      record = Jason.decode!(File.read!(path))
      assert record["targets"] == %{}
      assert record["source_index"] == %{}
      assert record["revision"] == 1

      assert ApplyEngine.execute(plan, %{"home" => home}) == plan.generation
      assert Jason.decode!(File.read!(path))["revision"] == 2
    end

    test "record_applied rejects list-shaped targets and source index fail-closed", %{home: home} do
      plan = build_plan(entries: [])
      install_fake_chezmoi(home, [])

      assert_raise ArgumentError, ~r/journal record targets must be a JSON object/, fn ->
        Journal.record_applied(home, plan.generation, [], %{}, plan.manifest, %{})
      end

      assert_raise ArgumentError, ~r/journal record source index must be a JSON object/, fn ->
        Journal.record_applied(home, plan.generation, %{}, %{}, plan.manifest, [])
      end

      assert Journal.applied(Path.join([home | EngineState.state_components()])) == nil
    end

    test "the journal tree is private: state components 0700, journal files 0600", %{home: home} do
      plan = build_plan()
      install_fake_chezmoi(home, deploy_instructions(home, plan))

      ApplyEngine.execute(plan, %{"home" => home})

      state_root = Path.join([home | EngineState.state_components()])
      assert mode_of(state_root) == 0o700
      assert mode_of(Path.join(state_root, "generations")) == 0o700
      assert mode_of(Path.join(state_root, "journal")) == 0o700
      assert mode_of(Path.join([state_root, "journal", "applied.json"])) == 0o600
    end

    test "re-applying the identical generation is an idempotent success that advances the revision", %{home: home} do
      plan = build_plan()
      install_fake_chezmoi(home, deploy_instructions(home, plan))

      assert ApplyEngine.execute(plan, %{"home" => home}) == plan.generation
      assert ApplyEngine.execute(plan, %{"home" => home}) == plan.generation

      record = Journal.applied(Path.join([home | EngineState.state_components()]))
      assert record["revision"] == 2
      assert record["generation"] == plan.generation

      # The re-apply produced byte-identical target fingerprints: the
      # published generation is content-addressed and the backend is
      # deterministic, so nothing in the record moves.
      assert record["targets"] == %{
               ".config/tooling/rc" =>
                 Map.merge(%{"type" => "file", "mode" => 0o644, "sha256" => Digest.sha256("export A=1\n")}, %{
                   "owner" => "tooling",
                   "operation" => "create",
                   "source_fingerprint" => "srcfp-rc"
                 })
             }
    end

    test "the real chezmoi binary applies the generation end to end when it is on PATH", %{home: home} do
      install_real_chezmoi(home)

      plan = build_plan(data: "profile = \"apply-sandbox\"\n")
      generation = ApplyEngine.execute(plan, %{"home" => home})
      assert generation == plan.generation

      assert File.read!(Path.join(home, ".config/tooling/rc")) == "export A=1\n"
      record = Journal.applied(Path.join([home | EngineState.state_components()]))
      assert record["generation"] == plan.generation

      # Second cycle through the real backend is idempotent too.
      assert ApplyEngine.execute(plan, %{"home" => home}) == plan.generation
      assert Journal.applied(Path.join([home | EngineState.state_components()]))["revision"] == 2
    end
  end

  describe "execute/2 failure anchors" do
    test "a failing backend run records journal/failed and keeps the pending anchor", %{home: home} do
      plan = build_plan()
      install_fake_chezmoi(home, "exit 7")

      assert_raise ArgumentError, ~r/chezmoi apply failed \(exit 7\)/, fn ->
        ApplyEngine.execute(plan, %{"home" => home})
      end

      state_root = Path.join([home | EngineState.state_components()])
      # No applied record exists: a failed run owns nothing.
      assert Journal.applied(state_root) == nil

      # The pending attempt record survives as the recovery anchor.
      pending = Journal.pending(state_root)
      assert [%{"generation" => generation, "entries" => 1, "targets" => [".config/tooling/rc"]}] = pending
      assert generation == plan.generation

      # The failed record carries the verbatim engine message and the
      # honest recovery note.
      failed_dir = Path.join([state_root, "journal", "failed"])
      [name] = File.ls!(failed_dir)
      failed = Path.join(failed_dir, name) |> File.read!() |> Jason.decode!()
      assert failed["generation"] == plan.generation
      assert failed["error"] =~ "chezmoi apply failed (exit 7)"
      assert failed["note"] == "partial apply is possible; recovery is conflict-aware, never a blind replay"
    end

    test "post-apply verification fails closed when the backend damages the generation", %{home: home} do
      plan = build_plan()
      directory = Path.join([home | EngineState.state_components() ++ ["generations", plan.generation]])

      # The fake backend produces the target AND corrupts its own --source
      # generation directory.
      install_fake_chezmoi(
        home,
        """
        mkdir -p '#{home}/.config/tooling'
        printf 'export A=1\\n' > '#{home}/.config/tooling/rc'
        printf 'tampered\\n' >> '#{directory}/dot_config/tooling/rc'
        """
      )

      assert_raise ArgumentError, ~r/generation/, fn ->
        ApplyEngine.execute(plan, %{"home" => home})
      end

      state_root = Path.join([home | EngineState.state_components()])
      # The journal record precedes the post-apply self-check (the ownership
      # claim is the journal; the generation damage is a separate corruption
      # signal), and the pending record was cleared by the completed
      # pipeline before verification ran.
      assert Journal.applied(state_root)["generation"] == plan.generation
      assert Journal.pending(state_root) == []
    end

    test "a requested generation that does not match the plan is the stale-plan refusal", %{home: home} do
      plan = build_plan()

      assert_raise ArgumentError, ~r/stale plan: requested generation/, fn ->
        ApplyEngine.execute(plan, %{"home" => home, "requested_generation" => String.duplicate("0", 64)})
      end

      # Nothing ran: no applied record, and the generation was never staged.
      state_root = Path.join([home | EngineState.state_components()])
      assert Journal.applied(state_root) == nil
      assert File.ls!(Path.join(state_root, "generations")) == []
    end
  end

  ## fixtures

  defp build_plan(opts \\ []) do
    entries =
      Keyword.get_lazy(opts, :entries, fn -> [file_entry() | Keyword.get(opts, :extra_entries, [])] end)

    data = if bytes = Keyword.get(opts, :data), do: %{owner: "tooling", bytes: bytes}, else: nil
    remove_file = Policy.remove_file([])

    base = [{".chezmoiremove", remove_file}]
    pinned = if data, do: base ++ [{".chezmoidata.toml", data.bytes}], else: base

    manifest = Manifest.build(entries, pinned)
    generation = Digest.sha256(Workstation.Core.CanonicalJSON.encode(manifest))

    %Source{
      entries: entries,
      removals: [],
      unsupported_reversals: [],
      profile: nil,
      fragments_journal: %{},
      remove_file: remove_file,
      journal_revision: 0,
      baseline_generation: nil,
      data: data,
      manifest: manifest,
      generation: generation
    }
  end

  defp file_entry do
    %{
      owner: "tooling",
      provider: "chezmoi",
      operation: "create",
      target: ".config/tooling/rc",
      source_name: "dot_config/tooling/rc",
      type: "file",
      mode: 0o644,
      bytes: "export A=1\n",
      link: nil,
      shared: nil,
      fingerprint: "srcfp-rc",
      exact: nil,
      template: nil,
      attribution: ["tooling"],
      fragments: nil
    }
  end

  defp executable_entry do
    %{
      file_entry()
      | target: ".local/bin/tool",
        source_name: "dot_local/bin/tool",
        mode: 0o755,
        bytes: "#!/bin/sh\necho tool\n",
        fingerprint: "srcfp-tool",
        shared: true
    }
  end

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

  # The real backend, resolved from PATH at test time, wrapped behind the
  # same pinned executable path production uses.
  defp install_real_chezmoi(home) do
    real = System.find_executable("chezmoi") || flunk("chezmoi is not on PATH")

    bin = Path.join([home, ".local", "opt", "chezmoi", "bin", "chezmoi"])
    File.mkdir_p!(Path.dirname(bin))
    File.write!(bin, "#!/bin/sh\nexec #{real} \"$@\"\n")
    File.chmod!(bin, 0o755)
    bin
  end

  defp mode_of(path) do
    %File.Stat{mode: mode} = File.stat!(path)
    Bitwise.band(mode, 0o777)
  end
end
