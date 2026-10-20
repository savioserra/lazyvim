defmodule Workstation.Core.Contracts.CopyTest do
  @moduledoc """
  The copied-payload contract: validation, the recorded seam, the declared
  fingerprint, the guarded source seam (chezmoi never derives state under
  the agent home), the serve semantics (idempotent byte-compare, staged
  writes, default-mode intermediates) and full pipeline cycles — including
  the hot-dir regression: a home whose pre-contract generation backend-
  tracked `.hermes` upgrades to the copy contract and applies green twice
  with the agent mutating the directory between applies.
  """

  use ExUnit.Case, async: false

  alias Workstation.Backends.Chezmoi
  alias Workstation.Core.Catalog
  alias Workstation.Core.Contracts.{Copy, Git}
  alias Workstation.Core.{Digest, Graph, Journal, Source}
  alias Workstation.Pipeline

  # The real agent payload the tests serve: resolution goes through the
  # catalog's one auditable asset seam against the engine checkout.
  @asset "files/.hermes/skills/secrets/SKILL.md"
  @owner "agent"
  @target ".hermes/skills/secrets/SKILL.md"

  setup context do
    home = Path.join(System.tmp_dir!(), "workstation-copy-#{context.test}-#{:os.getpid()}")
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

  describe "recipe validation" do
    test "a declared recipe validates and keeps its fields" do
      spec = Copy.recipe(%{"asset" => @asset, "target" => @target})

      assert %Copy{asset: @asset, target: @target, executable: nil} = spec
      assert :ok = Copy.validate_spec(spec)
    end

    test "an executable flag validates and survives the round trip" do
      spec = Copy.recipe(%{asset: "files/tool", target: ".local/bin/tool", executable: true})
      assert spec.executable == true
    end

    test "the asset must be a relative path inside its package" do
      for asset <- ["/etc/passwd", "~root/x", "../sibling", "a/../b", "back\\slash"] do
        assert_raise ArgumentError, ~r/copy asset/, fn ->
          Copy.recipe(%{asset: asset, target: ".config/x"})
        end
      end

      assert_raise ArgumentError, ~r/copy recipe requires asset/, fn ->
        Copy.recipe(%{asset: "", target: ".config/x"})
      end
    end

    test "the target must be a relative literal path inside the home" do
      for target <- ["/abs", "~home/x", "a/../b", "glob*", "with\nnewline", ".local/state/workstation/inside", ".local"] do
        assert_raise ArgumentError, ~r/copy target/, fn ->
          Copy.recipe(%{asset: "files/x", target: target})
        end
      end
    end

    test "executable must be boolean" do
      assert_raise ArgumentError, ~r/copy executable must be boolean/, fn ->
        Copy.recipe(%{asset: "files/x", target: ".config/x", executable: "yes"})
      end
    end

    test "validate_spec refuses a non-struct shape" do
      assert_raise ArgumentError, ~r/copy recipe must be a validated struct/, fn ->
        Copy.validate_spec(%{"asset" => "files/x"})
      end
    end
  end

  describe "the recorded seam" do
    test "a recorded spec denormalizes equal to the native declaration" do
      native = Copy.recipe(%{asset: @asset, target: @target, executable: true})
      recorded = Copy.from_recorded(%{"asset" => @asset, "target" => @target, "executable" => true}, %{package_id: @owner})

      assert recorded == native
      assert Copy.from_recorded(%{"asset" => @asset, "target" => @target}, %{package_id: @owner}) ==
               Copy.recipe(%{asset: @asset, target: @target})
    end

    test "an unknown recorded field fails closed" do
      assert_raise ArgumentError, ~r/unknown fields/, fn ->
        Copy.from_recorded(%{"asset" => @asset, "target" => @target, "version" => "1"}, %{package_id: @owner})
      end
    end

    test "an invalid recorded shape carries the package attribution" do
      assert_raise ArgumentError, ~r/invalid copy recipe for #{@owner}/, fn ->
        Copy.from_recorded(%{"target" => "/abs"}, %{package_id: @owner})
      end
    end
  end

  describe "the declared fingerprint" do
    test "identical declarations share one content address" do
      assert Copy.fingerprint(Copy.recipe(%{asset: @asset, target: @target})) ==
               Copy.fingerprint(Copy.recipe(%{asset: @asset, target: @target}))
    end

    test "any declared field moves the address" do
      base = Copy.fingerprint(Copy.recipe(%{asset: @asset, target: @target}))

      refute base == Copy.fingerprint(Copy.recipe(%{asset: "files/other", target: @target}))
      refute base == Copy.fingerprint(Copy.recipe(%{asset: @asset, target: ".hermes/other"}))
      refute base == Copy.fingerprint(Copy.recipe(%{asset: @asset, target: @target, executable: true}))
    end
  end

  describe "the guarded source seam" do
    test "a chezmoi file under the agent home fails closed at composition" do
      assert_raise ArgumentError,
                   ~r/recipe target is under the hot home \.hermes: \.hermes\/skills\/secrets\/SKILL\.md/,
                   fn ->
                     plan_for([package(@owner, [file_recipe(@target, "payload\n")])])
                   end
    end

    test "a chezmoi directory under the agent home fails closed too" do
      for target <- [".hermes", ".hermes/skills"] do
        assert_raise ArgumentError, ~r/under the hot home \.hermes: #{target}/, fn ->
          plan_for([package(@owner, [dir_recipe(target)])])
        end
      end
    end

    test "the copy recipe composes for the same target with zero source entries derived" do
      plan = plan_for([package(@owner, [copy_recipe(@asset, @target)])])

      assert [%{owner: @owner, target: @target, asset: @asset, fingerprint: fingerprint}] = plan.copies
      assert is_binary(fingerprint)
      assert plan.entries == []
      refute Enum.any?(plan.manifest, &String.contains?(Map.get(&1, :name, ""), "dot_hermes"))
    end

    test "the explicit removal tombstone inside the agent home stays declared" do
      plan = plan_for([package(@owner, [removal_recipe(".hermes/skills/lazyvim/SKILL.md")])])

      assert plan.declared_removals == [%{target: ".hermes/skills/lazyvim/SKILL.md", owner: @owner}]
    end

    test "the git clone under the agent home is unaffected by the guard" do
      plan = plan_for([package(@owner, [git_recipe(".hermes/hermes-agent")])])

      assert plan.entries == []
      assert plan.copies == []
    end

    test "copied targets own their path exclusively" do
      assert_raise ArgumentError, ~r/copy target \.config\/payload overlaps owned target \.config\/payload/, fn ->
        plan_for([package(@owner, [copy_recipe(@asset, ".config/payload"), file_recipe(".config/payload", "clash\n")])])
      end

      assert_raise ArgumentError, ~r/duplicate copy target #{@target}/, fn ->
        plan_for([package(@owner, [copy_recipe(@asset, @target), copy_recipe("files/other", @target)])])
      end

      assert_raise ArgumentError, ~r/copy target \.config\/payload overlaps owned target \.config\/payload\/deep/, fn ->
        plan_for([package(@owner, [copy_recipe(@asset, ".config/payload"), dir_recipe(".config/payload/deep")])])
      end

      assert_raise ArgumentError, ~r/declared removal \.hermes\/skills\/secrets overlaps copy target #{@target}/, fn ->
        plan_for([package(@owner, [copy_recipe(@asset, @target), removal_recipe(".hermes/skills/secrets")])])
      end

      assert_raise ArgumentError, ~r/copy target \.local\/bin\/pinned overlaps download target \.local\/bin\/pinned/, fn ->
        plan_for([
          package(@owner, [
            copy_recipe(@asset, ".local/bin/pinned"),
            download_recipe(".local/bin/pinned")
          ])
        ])
      end
    end
  end

  describe "the serve" do
    test "a fresh copy lands at 0644 with the served bytes", %{home: home} do
      :ok = Copy.run_effect(effect(), %{home: home})

      path = Path.join(home, @target)
      assert File.read!(path) == served_bytes()
      assert mode_of(path) == 0o644
    end

    test "the executable flag lands the payload at 0755", %{home: home} do
      :ok = Copy.run_effect(effect(executable: true), %{home: home})

      assert mode_of(Path.join(home, @target)) == 0o755
    end

    test "a byte-equal target is a no-op and keeps its inode", %{home: home} do
      path = Path.join(home, @target)
      :ok = Copy.run_effect(effect(), %{home: home})
      %File.Stat{inode: inode} = File.stat!(path)

      :ok = Copy.run_effect(effect(), %{home: home})

      assert %File.Stat{inode: ^inode} = File.stat!(path)
      assert File.read!(path) == served_bytes()
    end

    test "a declared executable flag converges the mode on skip without rewriting", %{home: home} do
      path = Path.join(home, @target)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, served_bytes())
      File.chmod!(path, 0o600)
      %File.Stat{inode: inode} = File.stat!(path)

      :ok = Copy.run_effect(effect(executable: true), %{home: home})

      assert mode_of(path) == 0o755
      assert %File.Stat{inode: ^inode} = File.stat!(path)
    end

    test "content drift is re-served through a staged write", %{home: home} do
      path = Path.join(home, @target)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "drifted\n")

      :ok = Copy.run_effect(effect(), %{home: home})

      assert File.read!(path) == served_bytes()
      # No staging residue beside the target.
      assert Path.dirname(path) |> File.ls!() |> Enum.all?(&(&1 == "SKILL.md"))
    end

    test "intermediate directories are created with default modes", %{home: home} do
      deep = ".hermes/skills/deep/inner/SKILL.md"

      :ok = Copy.run_effect(effect(target: deep), %{home: home})

      assert File.read!(Path.join(home, deep)) == served_bytes()
      assert mode_of(Path.join(home, ".hermes/skills/deep/inner")) == 0o755
    end

    test "a target that exists as a directory refuses instead of being replaced", %{home: home} do
      File.mkdir_p!(Path.join(home, @target))

      assert_raise ArgumentError, ~r/unreadable/, fn ->
        Copy.run_effect(effect(), %{home: home})
      end

      assert File.dir?(Path.join(home, @target))
    end

    test "the claim records the served target and refuses drift", %{home: home} do
      :ok = Copy.run_effect(effect(), %{home: home})

      sha = Digest.sha256(served_bytes())
      source_fingerprint = Copy.fingerprint(Copy.recipe(%{asset: @asset, target: @target}))

      assert %{
               @target => %{
                 "type" => "file",
                 "sha256" => ^sha,
                 "owner" => @owner,
                 "operation" => "copy",
                 "source_fingerprint" => ^source_fingerprint
               }
             } = Copy.fingerprint(effect(), %{home: home})

      File.write!(Path.join(home, @target), "mutated\n")

      assert_raise ArgumentError, ~r/does not carry the served asset bytes/, fn ->
        Copy.fingerprint(effect(), %{home: home})
      end
    end
  end

  describe "pipeline apply cycles" do
    test "a copy applies through the fold, claims its target, and re-applies idempotently", %{home: home} do
      package = package(@owner, [file_recipe(".config/tooling/rc", "export A=1\n"), copy_recipe(@asset, @target)])
      {:ok, plan} = Pipeline.composed_plan(home, collect([package]))
      install_fake_chezmoi(home, plan)

      assert Pipeline.execute(plan, %{"home" => home}) == plan.generation

      state_root = Path.join([home | Workstation.Core.EngineState.state_components()])
      record = Journal.applied(state_root)

      assert record["targets"][".config/tooling/rc"]["operation"] == "file"

      assert record["targets"][@target] == %{
               "type" => "file",
               "mode" => 0o644,
               "sha256" => Digest.sha256(served_bytes()),
               "owner" => @owner,
               "operation" => "copy",
               "source_fingerprint" => Copy.fingerprint(Copy.recipe(%{asset: @asset, target: @target}))
             }

      # The pending anchor carried the copy target among the desired surface.
      [retired_name] = File.ls!(Path.join([state_root, "journal", "retired"]))
      retired = Path.join([state_root, "journal", "retired", retired_name]) |> File.read!() |> Jason.decode!()
      assert @target in retired["targets"]

      assert File.read!(Path.join(home, @target)) == served_bytes()

      assert Pipeline.execute(plan, %{"home" => home}) == plan.generation
      assert Journal.applied(state_root)["revision"] == 2
    end
  end

  # The t_ec46e11e regression: the operator's Mac carried a pre-contract
  # generation whose backend tracked the skills payload (source entries
  # under `dot_hermes/`), so the agent's constant writes tripped
  # `has changed since chezmoi last wrote it?` on every apply. The
  # copy-contract generation derives zero backend state under `.hermes`:
  # the upgrade applies green, the tombstone retires the stale payload, and
  # the agent keeps mutating the directory between applies forever.
  describe "the hot-dir upgrade regression" do
    test "a pre-contract .hermes generation upgrades green on an agent-active home", %{home: home} do
      state_root = Path.join([home | Workstation.Core.EngineState.state_components()])

      # --- the pre-contract world: the backend wrote the payload, the
      # journal owns the old bytes, the retired skill is still on disk, and
      # the agent keeps live state under the same directory.
      old_bytes = "pre-contract payload\n"
      secrets_path = Path.join(home, @target)
      File.mkdir_p!(Path.dirname(secrets_path))
      File.write!(secrets_path, old_bytes)
      File.chmod!(secrets_path, 0o644)

      retired_skill = Path.join(home, ".hermes/skills/lazyvim/SKILL.md")
      File.mkdir_p!(Path.dirname(retired_skill))
      File.write!(retired_skill, "retired skill\n")

      noise = Path.join(home, ".hermes/memories/session.md")
      File.mkdir_p!(Path.dirname(noise))
      File.write!(noise, "agent state\n")

      :ok =
        Journal.record_applied(home, String.duplicate("0f", 32), %{
          @target => owned_record(old_bytes),
          ".hermes/skills/lazyvim/SKILL.md" => owned_record("retired skill\n")
        }, %{}, [], %{})

      # --- the copy-contract generation (HEAD): zero backend state under
      # .hermes, the tombstone declared beside the copy.
      package =
        package(@owner, [
          copy_recipe(@asset, @target),
          removal_recipe(".hermes/skills/lazyvim/SKILL.md"),
          file_recipe(".config/tooling/rc", "export A=1\n")
        ])

      {:ok, plan} = Pipeline.composed_plan(home, collect([package]))

      refute Enum.any?(plan.manifest, &String.contains?(Map.get(&1, :name, ""), "dot_hermes"))
      assert plan.removals == [%{target: ".hermes/skills/lazyvim/SKILL.md", owner: @owner}]

      install_real_chezmoi(home)
      assert Pipeline.execute(plan, %{"home" => home}) == plan.generation

      served = served_bytes()
      assert File.read!(secrets_path) == served
      refute File.exists?(retired_skill)
      assert File.read!(noise) == "agent state\n"
      assert File.read!(Path.join(home, ".config/tooling/rc")) == "export A=1\n"

      record = Journal.applied(state_root)
      assert record["targets"][@target]["operation"] == "copy"
      refute Map.has_key?(record["targets"], ".hermes/skills/lazyvim/SKILL.md")

      # --- the agent runs between applies: hot-dir writes are nobody's
      # conflict, and the second apply stays green.
      File.write!(Path.join(home, ".hermes/memories/late.md"), "mutated\n")

      assert Pipeline.execute(plan, %{"home" => home}) == plan.generation
      # The seed journal recorded revision 1; two applies advance it to 3.
      assert Journal.applied(state_root)["revision"] == 3
      assert File.read!(secrets_path) == served
    end
  end

  ## fixtures

  defp served_bytes, do: Catalog.package_asset!(@owner, @asset)

  defp effect(opts \\ []) do
    spec = Copy.recipe(%{asset: @asset, target: opts[:target] || @target, executable: opts[:executable]})

    %{
      contract: "copy",
      kind: :copy,
      phase: :target,
      owner: @owner,
      target: spec.target,
      asset: spec.asset,
      executable: spec.executable,
      fingerprint: Copy.fingerprint(spec)
    }
  end

  defp owned_record(bytes) do
    %{"type" => "file", "mode" => 0o644, "sha256" => Digest.sha256(bytes), "owner" => @owner, "operation" => "create"}
  end

  defp plan_for(packages), do: Source.plan(%{graph: Graph.order(%{host: "linux", specifications: packages})})

  defp collect(packages), do: fn -> {:ok, catalog(packages)} end

  defp catalog(packages) do
    %Catalog{profile: "test", host: "linux", home: "/home/test", packages: packages, assets: %{}}
  end

  defp package(id, contributes), do: %{id: id, requires: [], supported_hosts: nil, contributes: contributes}

  defp copy_recipe(asset, target, opts \\ []) do
    %{provider: "copy", spec: Copy.recipe(%{asset: asset, target: target, executable: opts[:executable]})}
  end

  defp file_recipe(target, content),
    do: %{provider: "chezmoi", spec: Chezmoi.recipe(%{target: target, kind: :file, content: content})}

  defp dir_recipe(target), do: %{provider: "chezmoi", spec: Chezmoi.recipe(%{target: target, kind: :directory})}

  defp removal_recipe(target), do: %{provider: "chezmoi", spec: Chezmoi.recipe(%{target: target, kind: :remove})}

  defp git_recipe(target),
    do: %{provider: "git", spec: Git.recipe(%{url: "https://goldens.invalid/git/repo.git", commit: String.duplicate("a", 40), target: target})}

  defp download_recipe(target) do
    %{provider: "download",
      spec:
        Workstation.Core.Contracts.Download.recipe(%{
          url: "https://goldens.invalid/pinned/1.0.0/pinned",
          version: "1.0.0",
          sha256: String.duplicate("a", 64),
          target: target
        })}
  end

  # A pinned fake backend: it produces the plan's entries (what the real
  # backend would deploy), so the claim step finds its targets.
  defp install_fake_chezmoi(home, plan) do
    bin = Path.join([home, ".local", "opt", "chezmoi", "bin", "chezmoi"])
    File.mkdir_p!(Path.dirname(bin))

    instructions =
      Enum.map_join(plan.entries, "\n", fn entry ->
        destination = Path.join(home, entry.target)
        body = String.replace(entry.bytes, "'", "'\\''")

        """
        mkdir -p '#{Path.dirname(destination)}'
        printf '%s' '#{body}' > '#{destination}'
        chmod #{Integer.to_string(entry.mode, 8)} '#{destination}'
        """
      end)

    File.write!(bin <> ".instructions", instructions)
    File.write!(bin, "#!/bin/sh\nsh '#{bin}.instructions'\n")
    File.chmod!(bin, 0o755)
    bin
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
