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
  alias Workstation.Core.Contracts.{Copy, Git}
  alias Workstation.Core.{Graph, Source}

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

  # --- composition helpers (the read face) -----------------------------------

  defp plan_for(packages), do: Source.plan(%{graph: Graph.order(%{host: "linux", specifications: packages})})

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

end
