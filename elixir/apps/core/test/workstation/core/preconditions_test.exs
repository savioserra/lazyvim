defmodule Workstation.Core.PreconditionsTest do
  @moduledoc """
  Pre-backend conflict cases against `check_preconditions`, exercised
  against real temporary homes. All contexts are pinned explicitly (`"home"`, `"journal"`,
  `"pending"`) so no test ever depends on — or mutates — a real environment.
  """

  use ExUnit.Case, async: false

  alias Workstation.Core.Preconditions

  setup do
    home = Path.join(System.tmp_dir!(), "workstation-b4-precond-#{:os.getpid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)

    on_exit(fn -> File.rm_rf!(home) end)

    %{home: home}
  end

  defp entry(extra) do
    Map.merge(
      %{
        "owner" => "tooling",
        "attribution" => ["tooling"],
        "provider" => "chezmoi",
        "operation" => "create",
        "target" => ".config/rc",
        "source_name" => "dot_config/rc",
        "type" => "file",
        "mode" => 0o644,
        "link" => nil,
        "shared" => nil,
        "fingerprint" => nil,
        "bytes" => "x"
      },
      extra
    )
  end

  defp plan(entries, extra \\ %{}) do
    Map.merge(
      %{
        "entries" => entries,
        "removals" => [],
        "journal_revision" => 1,
        "generation" => String.duplicate("ab", 32),
        "baseline_generation" => nil
      },
      extra
    )
  end

  defp journal(extra \\ %{}) do
    Map.merge(
      %{
        "revision" => 1,
        "generation" => String.duplicate("cd", 32),
        "targets" => %{},
        "fragments" => %{}
      },
      extra
    )
  end

  test "a plan built against an older journal revision is stale", %{home: home} do
    context = %{"home" => home, "journal" => journal(%{"revision" => 2}), "pending" => []}

    assert_raise ArgumentError, ~r/stale plan: it was built against journal revision 1 \(generation nil\), but revision 2 applied generation /, fn ->
      Preconditions.check(plan([entry(%{})]), context)
    end
  end

  test "re-applying the identical generation is idempotent, not stale", %{home: home} do
    context = %{
      "home" => home,
      "journal" => journal(%{"revision" => 7, "generation" => String.duplicate("ab", 32)}),
      "pending" => []
    }

    # Absent targets are adoptable, so nothing conflicts.
    assert Preconditions.check(plan([entry(%{})]), context) == :ok
  end

  test "unresolved partial attempts must be recovered explicitly", %{home: home} do
    File.write!(Path.join(home, "orphan"), "leftover")

    context = %{
      "home" => home,
      "journal" => journal(),
      "pending" => [
        %{"generation" => String.duplicate("99", 32), "targets" => ["orphan"]}
      ]
    }

    assert_raise ArgumentError,
                 ~r/unresolved partial attempt for generation .* touched orphan, which is neither recorded as owned nor desired/,
                 fn -> Preconditions.check(plan([]), context) end
  end

  test "targets of an old attempt that are still desired or owned do not block", %{home: home} do
    File.mkdir_p!(Path.join(home, ".config"))
    File.write!(Path.join(home, ".config/rc"), "older")
    File.write!(Path.join(home, "owned"), "recorded")

    context = %{
      "home" => home,
      "journal" =>
        journal(%{
          "targets" => %{"owned" => %{"type" => "file", "mode" => 0o644, "sha256" => Workstation.Core.EngineState.sha256("recorded")}}
        }),
      "pending" => [
        %{"generation" => String.duplicate("99", 32), "targets" => [".config/rc", "owned"]}
      ]
    }

    adoptable =
      entry(%{
        "expected" => %{
          "type" => "file",
          "mode" => 0o644,
          "sha256" => Workstation.Core.EngineState.sha256("older"),
          "link" => nil
        }
      })

    assert Preconditions.check(plan([adoptable]), context) == :ok
  end

  test "writes never go through symlinked ancestors", %{home: home} do
    outside = Path.join(home, "outside")
    File.mkdir_p!(outside)
    File.mkdir_p!(Path.join(home, ".config-real"))
    File.ln_s!(Path.join(home, ".config-real"), Path.join(home, ".config"))
    _ = outside

    context = %{"home" => home, "journal" => journal(), "pending" => []}

    assert_raise ArgumentError, ~r/refusing to write through symlinked ancestor .config for .config\/rc/, fn ->
      Preconditions.check(plan([entry(%{})]), context)
    end
  end

  test "directory operations conflict when the target exists as another type", %{home: home} do
    File.mkdir_p!(Path.join(home, ".config"))
    File.write!(Path.join(home, ".config/rc"), "a file")
    context = %{"home" => home, "journal" => journal(), "pending" => []}

    assert_raise ArgumentError, ~r/workstation apply conflict at .config\/rc \(owner tooling\): target exists as file/, fn ->
      Preconditions.check(plan([entry(%{"operation" => "directory", "type" => "directory"})]), context)
    end
  end

  test "exact directories fail closed on unproven content", %{home: home} do
    File.mkdir_p!(Path.join(home, ".config/exact"))
    File.mkdir_p!(Path.join(home, ".config"))
    File.write!(Path.join(home, ".config/exact/stray"), "unknown")
    context = %{"home" => home, "journal" => journal(), "pending" => []}

    assert_raise ArgumentError, ~r/exact directory contains unproven content stray/, fn ->
      Preconditions.check(
        plan([entry(%{"operation" => "directory", "target" => ".config/exact", "type" => "directory", "exact" => true})]),
        context
      )
    end
  end

  test "exact directories require proven ownership of existing children", %{home: home} do
    File.mkdir_p!(Path.join(home, ".config/exact"))
    File.mkdir_p!(Path.join(home, ".config"))
    File.write!(Path.join(home, ".config/exact/known"), "known")
    File.mkdir_p!(Path.join(home, ".config/exact/subdir"))

    context = %{
      "home" => home,
      "journal" => journal(%{"targets" => %{".config/exact/known" => %{"type" => "file", "mode" => 0o644}}}),
      "pending" => []
    }

    assert_raise ArgumentError, ~r/exact directory contains unproven subdirectory subdir/, fn ->
      Preconditions.check(
        plan([entry(%{"operation" => "directory", "target" => ".config/exact", "type" => "directory", "exact" => true})]),
        context
      )
    end

    File.rmdir!(Path.join(home, ".config/exact/subdir"))

    assert Preconditions.check(
             plan([entry(%{"operation" => "directory", "target" => ".config/exact", "type" => "directory", "exact" => true})]),
             context
           ) == :ok
  end

  test "shared modify targets must be files with intact fragments", %{home: home} do
    File.mkdir_p!(Path.join(home, ".zshrc"))
    context = %{"home" => home, "journal" => journal(), "pending" => []}

    assert_raise ArgumentError, ~r/shared target exists as directory/, fn ->
      Preconditions.check(
        plan([entry(%{"operation" => "modify", "target" => ".zshrc", "type" => "file", "shared" => true, "fragments" => []})]),
        context
      )
    end

    File.rm_rf!(Path.join(home, ".zshrc"))

    fragment = %{"id" => "app", "marker" => "# m", "body" => "export X=1", "order" => 1}
    File.write!(Path.join(home, ".zshrc"), "# m\nexport TAMPERED=1\n")

    assert_raise ArgumentError, ~r/edited, duplicated or ambiguous owned block for app/, fn ->
      Preconditions.check(
        plan([entry(%{"operation" => "modify", "target" => ".zshrc", "type" => "file", "shared" => true, "fragments" => [fragment]})]),
        context
      )
    end

    File.write!(Path.join(home, ".zshrc"), "# m\nexport X=1\n")

    assert Preconditions.check(
             plan([entry(%{"operation" => "modify", "target" => ".zshrc", "type" => "file", "shared" => true, "fragments" => [fragment]})]),
             context
           ) == :ok
  end

  test "recorded targets must match their journaled fingerprint", %{home: home} do
    File.mkdir_p!(Path.join(home, ".config"))
    File.write!(Path.join(home, ".config/rc"), "changed")

    context = %{
      "home" => home,
      "journal" =>
        journal(%{
          "targets" => %{".config/rc" => %{"type" => "file", "mode" => 0o644, "sha256" => Workstation.Core.EngineState.sha256("original")}}
        }),
      "pending" => []
    }

    assert_raise ArgumentError, ~r/target changed since the last successful apply/, fn ->
      Preconditions.check(plan([entry(%{})]), context)
    end

    File.mkdir_p!(Path.join(home, ".config"))
    File.write!(Path.join(home, ".config/rc"), "original")

    assert Preconditions.check(plan([entry(%{})]), context) == :ok
  end

  test "first adoption requires the expected whole-file state", %{home: home} do
    File.mkdir_p!(Path.join(home, ".config"))
    File.write!(Path.join(home, ".config/rc"), "unexpected")

    context = %{"home" => home, "journal" => journal(), "pending" => []}

    entry = entry(%{"expected" => %{"type" => "file", "mode" => 0o644, "sha256" => Workstation.Core.EngineState.sha256("expected")}})

    assert_raise ArgumentError,
                 ~r/first adoption of an existing unrecorded target differing in type, mode, content or link/,
                 fn -> Preconditions.check(plan([entry]), context) end

    File.mkdir_p!(Path.join(home, ".config"))
    File.write!(Path.join(home, ".config/rc"), "expected")
    assert Preconditions.check(plan([entry]), context) == :ok
  end

  test "backend-rendered targets without records or expectations conflict", %{home: home} do
    File.mkdir_p!(Path.join(home, ".config"))
    File.write!(Path.join(home, ".config/rc"), "mystery")
    context = %{"home" => home, "journal" => journal(), "pending" => []}

    assert_raise ArgumentError, ~r/backend-rendered target exists without an owned record/, fn ->
      Preconditions.check(plan([entry(%{})]), context)
    end
  end

  test "removals never adopt unrecorded targets and never remove changed state", %{home: home} do
    File.write!(Path.join(home, "mystery"), "never journaled")

    context = %{"home" => home, "journal" => journal(), "pending" => []}

    assert_raise ArgumentError, ~r/removal of mystery conflicts: it exists but was never recorded as owned/, fn ->
      Preconditions.check(plan([], %{"removals" => [%{"owner" => "x", "target" => "mystery"}]}), context)
    end

    File.rm!(Path.join(home, "mystery"))
    File.write!(Path.join(home, "owned"), "changed after apply")

    context =
      %{"home" => home, "journal" => journal(), "pending" => []}
      |> put_in(
        ["journal", "targets", "owned"],
        %{"type" => "file", "mode" => 0o644, "sha256" => Workstation.Core.EngineState.sha256("applied")}
      )

    assert_raise ArgumentError, ~r/removal of owned conflicts: the target changed since the last successful apply/, fn ->
      Preconditions.check(plan([], %{"removals" => [%{"owner" => "x", "target" => "owned"}]}), context)
    end

    File.write!(Path.join(home, "owned"), "applied")
    assert Preconditions.check(plan([], %{"removals" => [%{"owner" => "x", "target" => "owned"}]}), context) == :ok
  end

  test "a list-shaped journal targets index fails with the rebuild error, never an Access crash", %{home: home} do
    # The 2026-10-05 real-host crash shape: a journal written before
    # object-faithful record encoding carried "targets": [] and the
    # ownership lookups dereferenced it with a string key mid-check.
    File.write!(Path.join(home, "mystery"), "never journaled")

    poisoned = journal(%{"targets" => []})

    assert_raise ArgumentError, ~r/journal targets index is missing; rebuild the plan/, fn ->
      Preconditions.check(
        plan([], %{"removals" => [%{"owner" => "x", "target" => "mystery"}]}),
        %{"home" => home, "journal" => poisoned, "pending" => []}
      )
    end

    # The pending-attempt ownership lookup crashed the same way on the
    # poisoned index; the guard fires before any record is inspected.
    assert_raise ArgumentError, ~r/journal targets index is missing; rebuild the plan/, fn ->
      Preconditions.check(
        plan([entry(%{})]),
        %{
          "home" => home,
          "journal" => poisoned,
          "pending" => [%{"generation" => String.duplicate("99", 32), "targets" => ["mystery"]}]
        }
      )
    end
  end

  test "fragment integrity uses the journal's recorded fragment bodies", %{home: home} do
    fragment = %{"id" => "app", "marker" => "# m", "body" => "export NEW=1", "order" => 1}

    File.write!(Path.join(home, ".zshrc"), "# m\nexport OLD=0\n")

    context = %{
      "home" => home,
      "journal" =>
        journal(%{
          "fragments" => %{
            ".zshrc" => [%{"id" => "app", "marker" => "# m", "body" => "export OLD=0", "order" => 1}]
          }
        }),
      "pending" => []
    }

    # The recorded old body is what the file must still show before replace.
    assert Preconditions.check(
             plan([entry(%{"operation" => "modify", "target" => ".zshrc", "type" => "file", "shared" => true, "fragments" => [fragment]})]),
             context
           ) == :ok

    changed = %{fragment | "body" => "export CHANGED=9"}

    recorded_override =
      journal(%{
        "fragments" => %{
          ".zshrc" => [%{"id" => "app", "marker" => "# m", "body" => "export NEW=1", "order" => 1}]
        }
      })

    assert_raise ArgumentError, ~r/edited, duplicated or ambiguous owned block to be removed for app/, fn ->
      Preconditions.check(
        plan([entry(%{"operation" => "modify", "target" => ".zshrc", "type" => "file", "shared" => true, "fragments" => [changed]})]),
        %{"home" => home, "journal" => recorded_override, "pending" => []}
      )
    end
  end
end
