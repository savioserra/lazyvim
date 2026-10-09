defmodule Workstation.Core.ProvisionerTest do
  # `argv/2` and `Journal` read the effective home from the environment, so
  # every test pins WORKSTATION_HOME to its own temporary tree and restores it
  # afterwards; the real HOME is never touched.
  use ExUnit.Case, async: false

  alias Workstation.Core.EngineState
  alias Workstation.Core.Journal
  alias Workstation.Backends.Chezmoi
  alias Workstation.Core.Provisioner

  setup context do
    home = Path.join(System.tmp_dir!(), "workstation-provisioner-test-#{context.test}-#{:os.getpid()}")
    File.rm_rf!(home)
    File.mkdir_p!(home)
    System.put_env("WORKSTATION_HOME", home)

    on_exit(fn ->
      System.put_env("WORKSTATION_HOME", System.get_env("HOME") || "/root")
      File.rm_rf!(home)
    end)

    %{home: home}
  end

  describe "verify_generation/2" do
    test "accepts a generation directory that matches its manifest exactly" do
      root = generation_root()

      assert Provisioner.verify_generation(root, [
               %{"name" => ".config", "type" => "directory", "mode" => 0o755, "sha256" => nil},
               %{
                 "name" => ".config/rc",
                 "type" => "file",
                 "mode" => 0o644,
                 "sha256" => EngineState.sha256("export A=1\n")
               }
             ])
    end

    test "rejects a missing entry" do
      root = generation_root()
      # The manifest itself stays well-formed (every file entry carries a
      # digest, so structure asserts cannot fire first); the gap is on disk.
      File.rm!(Path.join(root, ".config/rc"))

      assert_raise ArgumentError, ~r/generation is missing entry: .config\/rc/, fn ->
        Provisioner.verify_generation(root, [
          %{
            "name" => ".config/rc",
            "type" => "file",
            "mode" => 0o644,
            "sha256" => EngineState.sha256("export A=1\n")
          }
        ])
      end
    end

    test "rejects the wrong type, mode and bytes" do
      root = generation_root()
      digest = EngineState.sha256("export A=1\n")

      assert_raise ArgumentError, ~r/generation entry has the wrong type: .config\/rc/, fn ->
        Provisioner.verify_generation(root, [%{"name" => ".config/rc", "type" => "directory", "mode" => 0o644, "sha256" => digest}])
      end

      assert_raise ArgumentError, ~r/generation entry has the wrong mode: .config\/rc/, fn ->
        Provisioner.verify_generation(root, [%{"name" => ".config/rc", "type" => "file", "mode" => 0o600, "sha256" => digest}])
      end

      assert_raise ArgumentError, ~r/generation entry has the wrong bytes: .config\/rc/, fn ->
        Provisioner.verify_generation(root, [%{"name" => ".config/rc", "type" => "file", "mode" => 0o644, "sha256" => EngineState.sha256("other")}])
      end
    end

    test "rejects unexpected entries in the generation" do
      root = generation_root()
      File.write!(Path.join(root, "stowaway"), "x")

      assert_raise ArgumentError, ~r/generation contains unexpected entries/, fn ->
        Provisioner.verify_generation(root, [%{"name" => ".config/rc", "type" => "file", "mode" => 0o644, "sha256" => EngineState.sha256("export A=1\n")}])
      end
    end

    test "rejects malformed manifests before touching the filesystem" do
      root = generation_root()

      assert_raise ArgumentError, "manifest entry has no name", fn ->
        Provisioner.verify_generation(root, [%{"type" => "file", "mode" => 0o644}])
      end

      assert_raise ArgumentError, "manifest file entry has no digest: .config/rc", fn ->
        Provisioner.verify_generation(root, [%{"name" => ".config/rc", "type" => "file", "mode" => 0o644}])
      end

      assert_raise ArgumentError, "duplicate manifest entry: .config/rc", fn ->
        entry = %{"name" => ".config/rc", "type" => "file", "mode" => 0o644, "sha256" => "x"}
        Provisioner.verify_generation(root, [entry, entry])
      end
    end
  end

  describe "argv/2" do
    test "pins the immutable source generation and destination explicitly" do
      source = "/gen/abcdef"
      destination = "/home/target"
      home = EngineState.home()

      assert Chezmoi.argv("apply", %{"source" => source, "destination" => destination}) == [
               Path.join([home, ".local", "opt", "chezmoi", "bin", "chezmoi"]),
               "--source",
               source,
               "--destination",
               destination,
               "apply",
               "--exclude",
               "scripts"
             ]
    end

    test "defaults the destination to the guarded home and appends dry-run and excludes" do
      home = EngineState.home()

      assert Chezmoi.argv("diff", %{"source" => "/gen/1", "dry_run" => true, "exclude" => ["scripts", "edit"]}) == [
               Path.join([home, ".local", "opt", "chezmoi", "bin", "chezmoi"]),
               "--source",
               "/gen/1",
               "--destination",
               home,
               "diff",
               "--dry-run",
               "--exclude",
               "scripts",
               "--exclude",
               "edit"
             ]
    end

    test "requires an explicit source generation" do
      assert_raise ArgumentError, "chezmoi argv requires an explicit source generation", fn ->
        Chezmoi.argv("apply", %{})
      end
    end

    test "default exclude is scripts" do
      argv = Chezmoi.argv("apply", %{"source" => "/gen/1"})

      assert Enum.slice(argv, -2, 2) == ["--exclude", "scripts"]
    end
  end

  describe "Journal applied/1" do
    test "reads the applied record from a guarded state tree" do
      state_root = guarded_state_root()
      generation = String.duplicate("ab", 32)

      File.mkdir_p!(Path.join(state_root, "journal"))

      File.write!(
        Path.join([state_root, "journal", "applied.json"]),
        ~s({"generation": "#{generation}", "revision": 3, "targets": {}})
      )

      assert Journal.applied(state_root) == %{"generation" => generation, "revision" => 3, "targets" => %{}}
    end

    test "returns nil when no generation was applied and on malformed records" do
      state_root = guarded_state_root()
      assert Journal.applied(state_root) == nil

      File.mkdir_p!(Path.join(state_root, "journal"))
      File.write!(Path.join([state_root, "journal", "applied.json"]), "{broken")

      assert Journal.applied(state_root) == nil
    end

    test "fails closed when the state chain is symlinked" do
      home = EngineState.home()
      state_root = guarded_state_root()
      File.rm_rf!(Path.join([home, ".local"]))
      File.mkdir_p!(Path.join(home, ".local-real"))
      File.ln_s!(Path.join(home, ".local-real"), Path.join([home, ".local"]))
      File.mkdir_p!(Path.join([state_root, "journal"]))

      # The guard walks the state chain plus the journal component, so the
      # failing walk is the journal-root one; the message still names the
      # violated component path (`.local`).
      assert_raise ArgumentError, ~r/journal root component is not a directory/, fn ->
        Journal.applied(state_root)
      end
    end

    test "fails closed when the journal component itself is symlinked" do
      # Parity anchor: state.lua journal_root guards the `journal` component
      # exactly like the state root; reading through a planted link would
      # hand unrelated state to the provenance decisions.
      state_root = guarded_state_root()
      File.rm_rf!(Path.join([state_root, "journal"]))
      File.mkdir_p!(Path.join(state_root, "journal-real"))
      File.ln_s!(Path.join(state_root, "journal-real"), Path.join(state_root, "journal"))

      assert_raise ArgumentError, ~r/journal root component is not a directory/, fn ->
        Journal.applied(state_root)
      end

      assert_raise ArgumentError, ~r/journal root component is not a directory/, fn ->
        Journal.pending(state_root)
      end
    end
  end

  describe "Journal pending/1" do
    test "lists pending records sorted by filename with the file attached" do
      state_root = guarded_state_root()
      pending = Path.join(state_root, "journal/pending")
      File.mkdir_p!(pending)
      File.write!(Path.join(pending, "2-second.json"), ~s({"generation": "#{String.duplicate("cd", 32)}", "targets": ["b"]}))
      File.write!(Path.join(pending, "1-first.json"), ~s({"generation": "#{String.duplicate("cd", 32)}", "targets": ["a"]}))
      File.write!(Path.join(pending, "3-broken.json"), "{nope")

      records = Journal.pending(state_root)

      assert Enum.map(records, & &1["file"]) == ["1-first.json", "2-second.json"]
      assert Enum.map(records, &hd(&1["targets"])) == ["a", "b"]
    end

    test "returns an empty list when the pending root is absent" do
      state_root = guarded_state_root()
      assert Journal.pending(state_root) == []
    end

    test "delegates fingerprints and digests to the engine state" do
      home = EngineState.home()
      File.write!(Path.join(home, "file"), "content")
      File.mkdir_p!(Path.join(home, "dir"))

      assert Journal.sha256("content") == EngineState.sha256("content")

      assert Journal.target_fingerprint(home, "file") == %{
               "type" => "file",
               "mode" => 0o644,
               "sha256" => EngineState.sha256("content")
             }

      assert Journal.target_fingerprint(home, "dir") == %{"type" => "directory", "mode" => 0o755}
      assert Journal.target_fingerprint(home, "absent") == nil
    end
  end

  defp generation_root do
    root = Path.join(System.tmp_dir!(), "workstation-generation-#{:os.getpid()}-#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, ".config"))
    File.write!(Path.join(root, ".config/rc"), "export A=1\n")

    on_exit(fn -> File.rm_rf!(root) end)

    root
  end

  # A guarded state chain: `.local/state/workstation/journal` with the state
  # root and the journal held at 0700, exactly what the engine's
  # `guarded_directory` would produce (journal_root uses the same mode).
  defp guarded_state_root do
    home = EngineState.home()
    state_root = Path.join([home, ".local", "state", "workstation"])
    File.mkdir_p!(Path.join(state_root, "journal"))
    File.chmod!(state_root, 0o700)
    File.chmod!(Path.join(state_root, "journal"), 0o700)
    state_root
  end
end
