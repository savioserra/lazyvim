defmodule Workstation.Core.ChangesetsTest do
  @moduledoc """
  Change-set and patch-parity cases against
  `workstation/lua/workstation/changesets.lua`, using explicit verified
  baseline fixtures so the diff bytes can be asserted as literals. The
  patches describe generated source only: nothing here ever reads or mutates
  a real home.
  """

  use ExUnit.Case, async: false

  # changesets/2 with a nil baseline falls back to the verified generation
  # under the effective home (anchor: `baseline = baseline or
  # verified_baseline()`); the suite pins WORKSTATION_HOME to an empty tree so
  # that fallback deterministically finds nothing and the real /root state is
  # never read.
  setup context do
    home = Path.join(System.tmp_dir!(), "workstation-changesets-test-#{context.test}-#{:os.getpid()}")
    File.rm_rf!(home)
    File.mkdir_p!(home)
    System.put_env("WORKSTATION_HOME", home)

    on_exit(fn ->
      System.put_env("WORKSTATION_HOME", System.get_env("HOME") || "/root")
      File.rm_rf!(home)
    end)

    :ok
  end

  alias Workstation.Core.Changesets

  defp plan(entries, extra \\ %{}) do
    Map.merge(
      %{
        "entries" => entries,
        "removals" => [],
        "remove_file" => ""
      },
      extra
    )
  end

  defp file_entry(name, bytes, extra \\ %{}) do
    Map.merge(
      %{
        "owner" => "tooling",
        "attribution" => ["tooling"],
        "provider" => "chezmoi",
        "operation" => "create",
        "target" => ".config/#{name}",
        "source_name" => name,
        "type" => "file",
        "mode" => 0o644,
        "link" => nil,
        "shared" => nil,
        "fingerprint" => "srcfp",
        "bytes" => bytes
      },
      extra
    )
  end

  defp baseline_dir(tmp, files) do
    directory = Path.join(tmp, "generation-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)

    Enum.each(files, fn
      {name, :dir} -> File.mkdir_p!(Path.join([directory | Path.split(name)]))
      {name, bytes} ->
        path = Path.join([directory | Path.split(name)])
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, bytes)
    end)

    directory
  end

  test "changesets list active entries with octal modes and typed metadata" do
    entries = [
      file_entry("dot_config/rc", "bytes", %{"mode" => 0o600, "type" => "file"}),
      %{
        "owner" => "tooling",
        "attribution" => ["tooling"],
        "provider" => "chezmoi",
        "operation" => "create",
        "target" => ".config/dir",
        "source_name" => "exact_private_dot_config",
        "type" => "directory",
        "mode" => 0o700,
        "link" => nil,
        "shared" => nil,
        "fingerprint" => nil,
        "bytes" => nil
      }
    ]

    [first, second] = Changesets.changesets(plan(entries), nil)

    assert first["source"] == "dot_config/rc"
    assert first["mode"] == "600"
    assert first["operation"] == "create"
    assert first["provider"] == "chezmoi"
    assert first["source_fingerprint"] == "srcfp"

    assert second["type"] == "directory"
    assert second["mode"] == "700"
    assert second["source_fingerprint"] == nil
  end

  test "retired source entries are attributed from the baseline source index" do
    tmp = System.tmp_dir!()
    directory = baseline_dir(tmp, [{"exact_private_dot_config/old", "gone"}])

    baseline = %{
      "generation" => String.duplicate("ab", 32),
      "directory" => directory,
      "manifest" => [
        %{"name" => "exact_private_dot_config/old", "type" => "file", "mode" => 0o600, "sha256" => "x"}
      ],
      "source_index" => %{
        "exact_private_dot_config/old" => %{
          "owner" => "legacy",
          "attribution" => ["legacy"],
          "target" => ".config/old",
          "type" => "file",
          "mode" => 0o600
        }
      }
    }

    on_exit(fn -> File.rm_rf!(directory) end)

    [retire] = Changesets.changesets(plan([]), baseline)

    assert retire["operation"] == "retire"
    assert retire["provider"] == "chezmoi"
    assert retire["owner"] == "legacy"
    assert retire["target"] == ".config/old"
    assert retire["source"] == "exact_private_dot_config/old"
    assert retire["mode"] == "600"
  end

  test "plan_patches emits a labeled unified diff for changed source bytes" do
    tmp = System.tmp_dir!()

    # A generated baseline always carries the tombstone file, even when empty;
    # with remove_file == "" the aggregate .chezmoiremove channel stays quiet.
    directory =
      baseline_dir(tmp, [{"dot_config/rc", "old line\n"}, {".chezmoiremove", ""}])

    baseline = %{
      "generation" => String.duplicate("cd", 32),
      "directory" => directory,
      "manifest" => [%{"name" => "dot_config/rc", "type" => "file", "mode" => 0o644, "sha256" => "x"}],
      "source_index" => %{"dot_config/rc" => %{"owner" => "tooling", "target" => ".config/rc", "type" => "file"}}
    }

    on_exit(fn -> File.rm_rf!(directory) end)

    entry = file_entry("dot_config/rc", "new line\n")

    assert [%{} = patch] = Changesets.plan_patches(plan([entry]), baseline)
    assert patch["kind"] == "change"
    assert patch["source"] == "dot_config/rc"

    assert patch["diff"] == """
           --- a/dot_config/rc
           +++ b/dot_config/rc
           @@ -1 +1 @@
           -old line
           +new line
           """
  end

  test "unchanged bytes produce no patch record" do
    tmp = System.tmp_dir!()
    directory = baseline_dir(tmp, [{"dot_config/rc", "same\n"}, {".chezmoiremove", ""}])

    baseline = %{
      "generation" => String.duplicate("ef", 32),
      "directory" => directory,
      "manifest" => [%{"name" => "dot_config/rc", "type" => "file", "mode" => 0o644, "sha256" => "x"}],
      "source_index" => %{"dot_config/rc" => %{"owner" => "tooling", "target" => ".config/rc", "type" => "file"}}
    }

    on_exit(fn -> File.rm_rf!(directory) end)

    assert [] == Changesets.plan_patches(plan([file_entry("dot_config/rc", "same\n")]), baseline)
  end

  test "new text entries are additions against /dev/null" do
    [add] = Changesets.plan_patches(plan([file_entry("dot_config/new", "hello\n")]), nil)

    assert add["kind"] == "add"
    assert add["diff"] == """
           --- a/dot_config/new
           +++ b/dot_config/new
           @@ -0,0 +1 @@
           +hello
           """
  end

  test "non-text entries keep typed metadata instead of a fabricated inverse" do
    tmp = System.tmp_dir!()

    dir_entry =
      file_entry("exact_private_dot_config", nil, %{"type" => "directory", "mode" => 0o700})

    assert [record] = Changesets.plan_patches(plan([dir_entry]), nil)
    assert record["kind"] == "add"
    assert Map.has_key?(record, "diff") == false
    assert record["mode"] == "700"

    # A directory already indexed in the baseline is not re-announced. The
    # baseline directory carries the always-present empty tombstone, exactly
    # like a generated baseline, so the aggregate channel stays quiet.
    directory = baseline_dir(tmp, [{".chezmoiremove", ""}])

    on_exit(fn -> File.rm_rf!(directory) end)

    baseline = %{
      "generation" => String.duplicate("12", 32),
      "directory" => directory,
      "manifest" => [],
      "source_index" => %{"exact_private_dot_config" => %{"owner" => "tooling"}}
    }

    assert [] == Changesets.plan_patches(plan([dir_entry]), baseline)
  end

  test "retired manifest files become attributed deletions, engine metadata excepted" do
    tmp = System.tmp_dir!()
    directory =
      baseline_dir(tmp, [
        {"dot_config/gone", "old\n"},
        {".chezmoiremove", "# engine tombstones\n"},
        {".chezmoidata.toml", "data = 1\n"}
      ])

    baseline = %{
      "generation" => String.duplicate("34", 32),
      "directory" => directory,
      "manifest" => [
        %{"name" => ".chezmoiremove", "type" => "file", "mode" => 0o600, "sha256" => "x"},
        %{"name" => ".chezmoidata.toml", "type" => "file", "mode" => 0o644, "sha256" => "x"},
        %{"name" => "dot_config/gone", "type" => "file", "mode" => 0o644, "sha256" => "x"}
      ],
      "source_index" => %{"dot_config/gone" => %{"owner" => "legacy", "target" => ".config/gone", "type" => "file"}}
    }

    on_exit(fn -> File.rm_rf!(directory) end)

    patches = Changesets.plan_patches(plan([]), baseline)

    assert [delete] = Enum.filter(patches, &(&1["kind"] == "delete"))
    assert delete["source"] == "dot_config/gone"
    assert delete["owner"] == "legacy"
    assert delete["diff"] =~ "-old\n"

    # The tombstone file changed from its recorded content, so the aggregate
    # change is present and names engine-policy (no removals in this plan).
    assert [aggregate] = Enum.filter(patches, &(&1["source"] == ".chezmoiremove"))
    assert aggregate["kind"] == "change"
    assert aggregate["owner"] == "engine"
    assert aggregate["attribution"] == ["engine-policy"]
    assert aggregate["target"] == ".chezmoiremove (aggregate tombstones)"
  end

  test "the aggregate tombstone names every removal owner exactly once" do
    tmp = System.tmp_dir!()
    directory = baseline_dir(tmp, [{".chezmoiremove", "old\n"}])

    baseline = %{
      "generation" => String.duplicate("56", 32),
      "directory" => directory,
      "manifest" => [%{"name" => ".chezmoiremove", "type" => "file", "mode" => 0o600, "sha256" => "x"}],
      "source_index" => %{}
    }

    on_exit(fn -> File.rm_rf!(directory) end)

    removals = [
      %{"owner" => "alpha", "target" => "a"},
      %{"owner" => "beta", "target" => "b"},
      %{"owner" => "alpha", "target" => "a2"}
    ]

    [aggregate] =
      Changesets.plan_patches(plan([], %{"removals" => removals, "remove_file" => "new\n"}), baseline)

    assert aggregate["attribution"] == ["engine-policy", "alpha", "beta"]
    assert aggregate["diff"] == """
           --- a/.chezmoiremove
           +++ b/.chezmoiremove
           @@ -1 +1 @@
           -old
           +new
           """
  end

  test "an identical tombstone body produces no aggregate change" do
    tmp = System.tmp_dir!()
    directory = baseline_dir(tmp, [{".chezmoiremove", "same\n"}])

    baseline = %{
      "generation" => String.duplicate("78", 32),
      "directory" => directory,
      "manifest" => [%{"name" => ".chezmoiremove", "type" => "file", "mode" => 0o600, "sha256" => "x"}],
      "source_index" => %{}
    }

    on_exit(fn -> File.rm_rf!(directory) end)

    assert [] == Changesets.plan_patches(plan([], %{"remove_file" => "same\n"}), baseline)
  end

  test "a malformed plan envelope cannot stage empty tombstone bytes" do
    tmp = System.tmp_dir!()
    directory = baseline_dir(tmp, [{".chezmoiremove", "old\n"}])

    baseline = %{
      "generation" => String.duplicate("9a", 32),
      "directory" => directory,
      "manifest" => [%{"name" => ".chezmoiremove", "type" => "file", "mode" => 0o600, "sha256" => "x"}],
      "source_index" => %{}
    }

    on_exit(fn -> File.rm_rf!(directory) end)

    assert_raise ArgumentError, ~r/plan remove_file must be a string/, fn ->
      Changesets.plan_patches(plan([], %{"remove_file" => nil}), baseline)
    end
  end

  # Real-host regression (c3 graduation): the CLI entry view feeds these
  # functions, and a journaled home resolves a REAL baseline here — fresh
  # sandbox journals (nil baseline) never reach the aggregate, which is why
  # only a live host caught the missing remove_file in the view.
  test "plan_patches records the aggregate tombstone change when the baseline body differs" do
    tmp = System.tmp_dir!()

    directory =
      baseline_dir(tmp, [{"dot_config/rc", "same\n"}, {".chezmoiremove", "stale-tombstone\n"}])

    on_exit(fn -> File.rm_rf!(directory) end)

    baseline = %{
      "generation" => String.duplicate("ab", 32),
      "directory" => directory,
      "manifest" => [%{"name" => "dot_config/rc", "type" => "file", "mode" => 0o644, "sha256" => "x"}],
      "source_index" => %{"dot_config/rc" => %{"owner" => "tooling", "target" => ".config/rc", "type" => "file"}}
    }

    patches =
      Changesets.plan_patches(
        plan([file_entry("dot_config/rc", "same\n")], %{"remove_file" => "fresh-tombstone\n"}),
        baseline
      )

    # The unchanged entry stays quiet; only the aggregate tombstone channel fires.
    assert [aggregate] = patches
    assert aggregate["kind"] == "change"
    assert aggregate["source"] == ".chezmoiremove"
    assert aggregate["owner"] == "engine"
    assert aggregate["attribution"] == ["engine-policy"]
    assert aggregate["target"] == ".chezmoiremove (aggregate tombstones)"
    assert aggregate["diff"] =~ "+fresh-tombstone"
  end

  test "plan_patches fail closed when a baseline-backed plan omits remove_file" do
    tmp = System.tmp_dir!()
    directory = baseline_dir(tmp, [{"dot_config/rc", "same\n"}, {".chezmoiremove", "body\n"}])

    on_exit(fn -> File.rm_rf!(directory) end)

    baseline = %{
      "generation" => String.duplicate("33", 32),
      "directory" => directory,
      "manifest" => [%{"name" => "dot_config/rc", "type" => "file", "mode" => 0o644, "sha256" => "x"}],
      "source_index" => %{"dot_config/rc" => %{"owner" => "tooling", "target" => ".config/rc", "type" => "file"}}
    }

    view = plan([file_entry("dot_config/rc", "same\n")]) |> Map.delete("remove_file")

    assert_raise ArgumentError, ~r/plan remove_file must be a string/, fn ->
      Changesets.plan_patches(view, baseline)
    end
  end
end
