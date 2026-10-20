defmodule Workstation.Core.PreconditionsTest do
  @moduledoc """
  Pre-backend conflict cases against `check_preconditions`, exercised
  against real temporary homes. All contexts are pinned explicitly (`"home"`, `"journal"`,
  `"pending"`) so no test ever depends on — or mutates — a real environment.
  """

  use ExUnit.Case, async: false

  # Fixture homes are cross-VM collision-proof: `System.unique_integer/1`
  # restarts its sequence in every `mix test` VM, so a home that outlives its
  # run (a killed run's leftovers) is re-drawn verbatim by a later one. The
  # boot millisecond in base36 never repeats across VMs, any same-named
  # leftover is swept before use, and the home is removed on exit (the full
  # note lives in apps/daemon/test/workstation/daemon/generation_test.exs).
  defp unique_home(prefix) do
    token = Integer.to_string(:os.system_time(:millisecond), 36)
    home = Path.join(System.tmp_dir!(), "#{prefix}-#{token}")

    File.rm_rf!(home)
    on_exit(fn -> File.rm_rf!(home) end)
    home
  end


  alias Workstation.Core.Preconditions

  setup do
    home = unique_home("workstation-b4-precond")
    File.mkdir_p!(home)

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
                 ~r/unresolved partial attempt for generation .* touched orphan, which is neither recorded as owned nor desired \(payload target: remove or back it up explicitly, then re-apply/,
                 fn -> Preconditions.check(plan([]), context) end
  end

  test "every stale attempt's unreconciled targets refuse ONCE, each with its class door", %{home: home} do
    # A payload straggler and a bootstrap-provisioned straggler from two
    # different stale records: one pass collects both, one refusal names
    # both — never one straggler per apply cycle.
    File.write!(Path.join(home, "stray"), "leftover")

    File.mkdir_p!(Path.join(home, ".local/opt/mise/2026.10.8/bin"))
    File.write!(Path.join(home, ".local/opt/mise/2026.10.8/bin/mise"), "stale pinned binary")

    context = %{
      "home" => home,
      "journal" => journal(),
      "pending" => [
        %{"generation" => String.duplicate("99", 32), "targets" => ["stray"]},
        %{"generation" => String.duplicate("77", 32), "targets" => [".local/opt/mise/2026.10.8/bin/mise"]}
      ]
    }

    error =
      assert_raise ArgumentError, fn ->
        Preconditions.check(plan([]), context)
      end

    message = Exception.message(error)
    assert message =~ "2 unresolved partial attempt targets"
    assert message =~ "the full set is computed before any mutation"
    assert message =~ "touched stray, which is neither recorded as owned nor desired (payload target:"
    assert message =~
             "touched .local/opt/mise/2026.10.8/bin/mise, which is neither recorded as owned nor desired " <>
               "(bootstrap-provisioned surface: remove the stale artifact explicitly"
  end

  test "a stale attempt whose targets are all bootstrap-provisioned but still desired does not block", %{home: home} do
    # The 2026-10-19 convergence catch-22: the interrupted attempt touched
    # only bootstrap-provisioned surface (the pinned download, the managed
    # config, its PATH link, the state directory) — targets no backend entry
    # ever declares. The next generation desires exactly that surface, so
    # the guard reconciles it (the fold re-produces every target) instead of
    # demanding recovery only a successful apply could perform.
    for target <- [
          ".local/opt/mise/2026.11.1/bin/mise",
          ".config/mise/config.toml",
          ".local/bin/mise",
          ".local/state/workstation/mise"
        ] do
      path = Path.join(home, target)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "half-applied")
    end

    context = %{
      "home" => home,
      "journal" => journal(),
      "pending" => [
        %{
          "generation" => String.duplicate("79", 32),
          "targets" => [
            ".local/opt/mise/2026.11.1/bin/mise",
            ".config/mise/config.toml",
            ".local/bin/mise",
            ".local/state/workstation/mise"
          ]
        }
      ]
    }

    desired_surface = [
      ".local/opt/mise/2026.11.1/bin/mise",
      ".config/mise/config.toml",
      ".local/bin/mise",
      ".local/state/workstation/mise"
    ]

    assert Preconditions.check(
             plan([], %{"desired" => desired_surface}),
             context
           ) == :ok
  end

  test "a stale attempt's engine-state straggler refuses once with the bootstrap-surface door", %{home: home} do
    File.mkdir_p!(Path.join(home, ".local/state/workstation/mise"))
    File.write!(Path.join(home, ".local/state/workstation/mise/cache"), "leftover")

    context = %{
      "home" => home,
      "journal" => journal(),
      "pending" => [
        %{"generation" => String.duplicate("77", 32), "targets" => [".local/state/workstation/mise"]}
      ]
    }

    assert_raise ArgumentError,
                 ~r/touched \.local\/state\/workstation\/mise, which is neither recorded as owned nor desired \(bootstrap-provisioned surface:/,
                 fn -> Preconditions.check(plan([], %{"desired" => [".local/opt/mise/2026.11.1/bin/mise"]}), context) end
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

    fragment = %{"id" => "app", "marker" => "# m", "body" => "export X=1"}
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

  test "an interrupted same-generation fold converges on retry", %{home: home} do
    File.mkdir_p!(Path.join(home, ".config"))
    # The interrupted attempt of THIS plan's generation already rewrote the
    # owned target, so it no longer matches the last successful journal.
    File.write!(Path.join(home, ".config/rc"), "half-applied")

    context = %{
      "home" => home,
      "journal" =>
        journal(%{
          "targets" => %{".config/rc" => %{"type" => "file", "mode" => 0o644, "sha256" => Workstation.Core.EngineState.sha256("original")}}
        }),
      "pending" => [
        %{"generation" => String.duplicate("ab", 32), "targets" => [".config/rc"]}
      ]
    }

    assert Preconditions.check(plan([entry(%{})]), context) == :ok
  end

  test "a foreign-generation pending attempt does not excuse a changed owned target", %{home: home} do
    File.mkdir_p!(Path.join(home, ".config"))
    File.write!(Path.join(home, ".config/rc"), "changed")

    context = %{
      "home" => home,
      "journal" =>
        journal(%{
          "targets" => %{".config/rc" => %{"type" => "file", "mode" => 0o644, "sha256" => Workstation.Core.EngineState.sha256("original")}}
        }),
      "pending" => [
        %{"generation" => String.duplicate("99", 32), "targets" => [".config/rc"]}
      ]
    }

    assert_raise ArgumentError, ~r/target changed since the last successful apply/, fn ->
      Preconditions.check(plan([entry(%{})]), context)
    end
  end

  test "a converging retry leaves the pending and failed evidence untouched", %{home: home} do
    File.mkdir_p!(Path.join(home, ".config"))
    File.write!(Path.join(home, ".config/rc"), "half-applied")

    state_root = Path.join([home | Workstation.Core.EngineState.state_components()])
    generation = String.duplicate("ab", 32)

    :ok =
      Workstation.Core.Journal.write_pending(home, %{
        "generation" => generation,
        "at" => System.system_time(:second),
        "pid" => :os.getpid(),
        "entries" => 1,
        "targets" => [".config/rc"]
      })

    :ok = Workstation.Core.Journal.write_failed(home, generation, %ArgumentError{message: "backend interrupted"})

    pending = Workstation.Core.Journal.pending(state_root)
    assert [%{"generation" => ^generation, "targets" => [".config/rc"]}] = pending

    context = %{
      "home" => home,
      "journal" =>
        journal(%{
          "targets" => %{".config/rc" => %{"type" => "file", "mode" => 0o644, "sha256" => Workstation.Core.EngineState.sha256("original")}}
        }),
      "pending" => pending
    }

    assert Preconditions.check(plan([entry(%{})]), context) == :ok

    # The read-only check consumed neither the pending anchor nor the failed
    # record: recovery stays conflict-aware, never a silent evidence purge.
    assert Workstation.Core.Journal.pending(state_root) == pending

    failed_dir = Path.join([state_root, "journal", "failed"])
    assert [failed_name] = File.ls!(failed_dir)
    assert String.starts_with?(failed_name, generation <> "-")
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

  test "the refusal carries the COMPLETE un-owned set in one failure", %{home: home} do
    # Three un-owned stragglers across two packages: the operating contract
    # computes the full set before anything is touched, so ONE apply names
    # all of them — never one per collect/apply cycle.
    File.mkdir_p!(Path.join(home, ".config"))

    Enum.each([".config/a", ".config/b", ".config/c", "stray"], fn target ->
      File.write!(Path.join(home, target), "mystery")
    end)

    context = %{"home" => home, "journal" => journal(), "pending" => []}

    entries = [
      entry(%{"target" => ".config/a", "source_name" => "dot_config/a", "attribution" => ["tooling"]}),
      entry(%{"target" => ".config/b", "source_name" => "dot_config/b", "attribution" => ["tooling"]}),
      entry(%{"target" => ".config/c", "source_name" => "dot_config/c", "attribution" => ["other"]})
    ]

    error =
      assert_raise ArgumentError, fn ->
        Preconditions.check(plan(entries, %{"removals" => [%{"owner" => "x", "target" => "stray"}]}), context)
      end

    message = Exception.message(error)
    assert message =~ ~r/workstation apply refused: 4 target conflicts/
    assert message =~ "the full set is computed before any mutation"
    # Every line keeps the exact single-conflict wording, so per-target
    # greps and the verbatim wire render stay stable.
    Enum.each([".config/a", ".config/b", ".config/c"], fn target ->
      assert message =~ "workstation apply conflict at #{target} (owner "
      assert message =~ "backend-rendered target exists without an owned record"
    end)

    assert message =~ "removal of stray conflicts: it exists but was never recorded as owned"
  end

  test "the probe verdict rides the plain refusal: matching orphans point at the adopt door", %{home: home} do
    # An honest hand install: byte-identical to what the plan renders.
    File.mkdir_p!(Path.join(home, ".config"))
    File.write!(Path.join(home, ".config/rc"), "x")
    File.chmod!(Path.join(home, ".config/rc"), 0o644)
    context = %{"home" => home, "journal" => journal(), "pending" => []}

    error = assert_raise ArgumentError, fn -> Preconditions.check(plan([entry(%{})]), context) end
    assert Exception.message(error) =~ "probe: the on-disk state matches what the plan renders"
    assert Exception.message(error) =~ "workstation apply --adopt"
  end

  test "the operator-gated adopt door adopts probe-verified targets and refuses the rest", %{home: home} do
    # Verified: byte- and mode-identical to the plan's rendered target.
    File.mkdir_p!(Path.join(home, ".config"))
    File.write!(Path.join(home, ".config/rc"), "x")
    File.chmod!(Path.join(home, ".config/rc"), 0o644)

    # Foreign: same target path semantics, different bytes.
    File.write!(Path.join(home, ".config/other"), "hand edit")

    context = %{
      "home" => home,
      "journal" => journal(),
      "pending" => [],
      "adopt" => true
    }

    verified = entry(%{})
    foreign = entry(%{"target" => ".config/other", "source_name" => "dot_config/other", "bytes" => "engine bytes"})

    # The probe-verified target passes; the differing one still conflicts,
    # fail-closed, with the reason named.
    error =
      assert_raise ArgumentError, fn ->
        Preconditions.check(plan([verified, foreign]), context)
      end

    refute Exception.message(error) =~ ".config/rc"
    assert Exception.message(error) =~ "workstation apply conflict at .config/other (owner tooling)"
    assert Exception.message(error) =~ "probe: on-disk content differs from the rendered bytes"
  end

  test "adopt probes a symlink target by its rendered link value", %{home: home} do
    File.mkdir_p!(Path.join(home, ".local/bin"))
    File.ln_s!("../opt/tool/bin/tool", Path.join(home, ".local/bin/tool"))

    link =
      entry(%{
        "target" => ".local/bin/tool",
        "source_name" => "dot_local/bin/tool",
        "type" => "link",
        "mode" => nil,
        "bytes" => "../opt/tool/bin/tool",
        "link" => "../opt/tool/bin/tool"
      })

    # Without the gate the honest copy still conflicts (with the verdict).
    plain = assert_raise ArgumentError, fn -> Preconditions.check(plan([link]), %{"home" => home, "journal" => journal(), "pending" => []}) end
    assert Exception.message(plain) =~ "probe: the on-disk state matches what the plan renders"

    assert Preconditions.check(plan([link]), %{"home" => home, "journal" => journal(), "pending" => [], "adopt" => true}) == :ok

    # A foreign link target is never adopted.
    File.rm!(Path.join(home, ".local/bin/tool"))
    File.ln_s!("somewhere-else", Path.join(home, ".local/bin/tool"))

    error =
      assert_raise ArgumentError, fn ->
        Preconditions.check(plan([link]), %{"home" => home, "journal" => journal(), "pending" => [], "adopt" => true})
      end

    assert Exception.message(error) =~ "probe: on-disk link is somewhere-else, the plan renders ../opt/tool/bin/tool"
  end

  test "template entries are probe-unverifiable and never adopted", %{home: home} do
    File.mkdir_p!(Path.join(home, ".config"))
    File.write!(Path.join(home, ".config/rc"), "rendered by the backend")
    context = %{"home" => home, "journal" => journal(), "pending" => [], "adopt" => true}

    # bytes here are the template SOURCE, not the rendered form: no
    # byte-identity verdict can exist before the backend renders.
    template = entry(%{"template" => true, "bytes" => "{{ profile }} rc"})

    error = assert_raise ArgumentError, fn -> Preconditions.check(plan([template]), context) end

    assert Exception.message(error) =~ "probe: not verifiable before the backend renders"
    assert Exception.message(error) =~ "the entry renders through the backend template pass"
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
    fragment = %{"id" => "app", "marker" => "# m", "body" => "export NEW=1"}

    File.write!(Path.join(home, ".zshrc"), "# m\nexport OLD=0\n")

    context = %{
      "home" => home,
      "journal" =>
        journal(%{
          "fragments" => %{
            ".zshrc" => [%{"id" => "app", "marker" => "# m", "body" => "export OLD=0"}]
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
          ".zshrc" => [%{"id" => "app", "marker" => "# m", "body" => "export NEW=1"}]
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
