defmodule Workstation.Core.Preconditions do
  @moduledoc """
  Layer: kernel. The kernel law: this module names no package, no backend and no
  consumer -- it speaks only contracts and shapes (docs/architecture.md,
  "Module hierarchy & moduledoc conventions").
  Read-only actual-target precondition checks for every planned mutation.
  Read-only by law: a refused plan leaves the home untouched.

  Intervening home edits (full type/mode/content/link state), first adoption
  of unrecorded whole files, exact-directory ownership of existing contents,
  shared-target fragment integrity and removal safety all conflict BEFORE any
  backend mutation. One exception keeps the retry law honest: targets that a
  pending attempt of the SAME generation already wrote are excused from the
  owned-fingerprint equality check, because that on-disk state is the plan's
  own; pending records of any other generation still guard. The plan is bound
  to the journal revision it was built against. This module never mutates
  anything: conflicts raise, and the engine stays the sole writer of home and
  journal state.

  The refusal carries the COMPLETE conflict set: every entry and every
  removal is checked in one pass and the failures raise together (the
  operating contract computes the full set before anything is touched, so a
  converged host with many un-owned stragglers surfaces them in one apply,
  never one per cycle). Each conflict line keeps the exact single-conflict
  wording, so per-target greps and the verbatim wire render stay stable; a
  lone conflict raises its legacy line alone. The journal-shape, stale-plan
  and unresolved-attempt guards still refuse immediately: they are plan-level
  invariants, not per-target conflicts.

  Un-owned targets (backend-rendered state with no journal record) also carry
  a read-only probe verdict: whether the on-disk state is byte-identical to
  what the plan renders. The probe feeds the operator-gated adoption door —
  context `"adopt"` (the CLI's `apply --adopt`) treats a probe-verified
  target as adoptable, and the apply's own claim step records its ownership;
  anything the probe cannot verify (differing bytes, foreign type, or a
  template entry whose rendered form only exists after the backend runs)
  still conflicts, fail-closed. Content identity is the law: the engine state
  wins the cutover, never a hand edit (docs/chezmoi.md, "Guarded-apply
  recovery").
  """

  alias Workstation.Core.EngineState
  alias Workstation.Core.Journal
  alias Workstation.Core.ShellProgram

  defp is_within(target, ancestor) do
    target == ancestor or String.starts_with?(target, ancestor <> "/")
  end

  # ONE conflict wording, shared by the single raise and every line of the
  # aggregate: the target, its owners, the refusal.
  defp conflict_message(entry, message) do
    "workstation apply conflict at #{entry["target"]} (owner #{Enum.join(entry["attribution"] || [], ",")}): #{message}"
  end

  @doc """
  Check every planned mutation against the actual home. `context` may pin
  `"home"`, the applied journal record (`"journal"`), `"pending"` records and
  the operator-gated adoption door (`"adopt"`) for tests; nil derives home,
  journal and pending from the environment, exactly like the anchor. Returns
  :ok or raises ArgumentError naming the complete conflict set.
  """
  @spec check(map(), map() | nil) :: :ok
  def check(plan, context) do
    context = context || %{}
    home = context["home"] || EngineState.home()
    state_root = EngineState.state_root()
    journal = if Map.has_key?(context, "journal"), do: context["journal"], else: Journal.applied(state_root)

    # Journal shape guard: the ownership lookups below dereference
    # journal["targets"][target] directly. A list-shaped index (journals
    # written before object-faithful record encoding, or hand edits) must
    # fail with the actionable rebuild error here, not with an Access
    # crash part-way through the checks.
    if journal && not is_map(journal["targets"]) do
      raise(ArgumentError, "journal targets index is missing; rebuild the plan")
    end

    pending = if Map.has_key?(context, "pending"), do: context["pending"], else: Journal.pending(state_root)

    current_revision = (journal && journal["revision"]) || 0
    current_generation = journal && journal["generation"]

    # A plan is stale when a different successful generation was applied after
    # it was built. Re-applying the identical desired generation is an
    # idempotent no-op, not staleness; fingerprints still guard every target.
    stale = current_revision != plan["journal_revision"] and current_generation != plan["generation"]

    if stale do
      raise(ArgumentError,
        "stale plan: it was built against journal revision #{inspect(plan["journal_revision"])} " <>
          "(generation #{inspect(plan["baseline_generation"])}), but revision #{inspect(current_revision)} " <>
          "applied generation #{inspect(current_generation)}; rebuild the plan"
      )
    end

    # Unresolved partial attempts are never silently forgotten: when the
    # desired generation changed, any target the attempt touched that is
    # neither proven owned (journal) nor still desired must be recovered
    # explicitly before a new generation may apply.
    Enum.each(pending, fn record ->
      if record["generation"] != plan["generation"] do
        Enum.each(record["targets"] || [], fn target ->
          owned = journal && journal["targets"] && journal["targets"][target]

          if owned == nil and not MapSet.member?(MapSet.new(plan["entries"], & &1["target"]), target) and
               EngineState.lstat(EngineState.join_home(home, target)) != nil do
            raise(ArgumentError,
              "workstation apply conflict: unresolved partial attempt for generation #{record["generation"]} " <>
                "touched #{target}, which is neither recorded as owned nor desired; inspect the journal and recover explicitly"
            )
          end
        end)
      end
    end)

    # Same-generation pending attempts are the plan's own writes: a pending
    # record whose generation equals the plan's proves that any on-disk drift
    # on its targets came from THIS interrupted fold, so the owned-target
    # fingerprint equality check is excused for exactly those targets and
    # retrying the same desired generation converges idempotently. Pending
    # records of any other generation keep the unresolved-attempt guard above.
    excused =
      pending
      |> Enum.filter(fn record -> record["generation"] == plan["generation"] end)
      |> Enum.flat_map(fn record -> record["targets"] || [] end)
      |> MapSet.new()

    adopt = context["adopt"] == true

    # ONE pass over every entry and every removal: the full conflict set is
    # computed before anything is refused, so the operator never pays a
    # collect/apply cycle per straggler.
    conflicts =
      Enum.flat_map(plan["entries"], fn entry ->
        check_entry(home, journal, entry, excused, adopt)
      end) ++
        Enum.flat_map(plan["removals"] || [], fn removal ->
          check_removal(home, journal, removal)
        end)

    case conflicts do
      [] -> :ok
      [only] -> raise(ArgumentError, only)

      _many ->
        raise(
          ArgumentError,
          "workstation apply refused: #{length(conflicts)} target conflicts " <>
            "(the full set is computed before any mutation; per-target recovery: the guarded-apply recovery runbook):\n" <>
            Enum.join(conflicts, "\n")
        )
    end
  end

  # Never write through a symlinked ancestor into unrelated state.
  defp ancestor_conflicts(home, target, ancestor) do
    if ancestor do
      ancestor_stat = EngineState.lstat(EngineState.join_home(home, ancestor))

      if ancestor_stat != nil and ancestor_stat.type == "link" do
        ["refusing to write through symlinked ancestor #{ancestor} for #{target}"]
      else
        ancestor_conflicts(home, target, ancestor_of(ancestor))
      end
    else
      []
    end
  end

  defp ancestor_of(target) do
    case Regex.run(~r{\A(.*)/[^/]+\z}, target) do
      [_all, ancestor] -> ancestor
      _other -> nil
    end
  end

  # One entry's conflicts, in report order. A structural refusal (symlinked
  # ancestor, wrong target type) ends the entry's probes: deeper verdicts
  # would read through the very state that refused.
  defp check_entry(home, journal, entry, excused, adopt) do
    target = entry["target"]
    path = EngineState.join_home(home, target)
    stat = EngineState.lstat(path)

    with [] <- ancestor_conflicts(home, target, ancestor_of(target)) do
      cond do
        entry["operation"] == "directory" ->
          directory_conflicts(home, journal, entry, stat)

        stat == nil ->
          # absent targets are adoptable
          []

        entry["operation"] == "modify" ->
          modify_conflicts(journal, entry, path, stat)

        true ->
          owned_target_conflicts(home, journal, entry, excused, adopt)
      end
    end
  end

  defp directory_conflicts(home, journal, entry, stat) do
    cond do
      stat && stat.type != "directory" ->
        [conflict_message(entry, "target exists as #{stat.type}")]

      entry["exact"] && stat ->
        # Exact management prunes anything unknown inside the target:
        # adoption requires complete proven ownership of the existing
        # contents, otherwise it fails closed. Every unproven child is
        # named, so one apply reports the whole straggler set.
        journal_targets = (journal && journal["targets"]) || %{}
        owned = MapSet.new(Map.keys(journal_targets))
        path = EngineState.join_home(home, entry["target"])

        File.ls!(path)
        |> Enum.sort()
        |> Enum.flat_map(fn child ->
          child_stat = EngineState.lstat(Path.join(path, child))

          cond do
            child_stat && child_stat.type == "directory" ->
              [conflict_message(entry, "exact directory contains unproven subdirectory #{child}")]

            not MapSet.member?(owned, entry["target"] <> "/" <> child) ->
              [conflict_message(entry, "exact directory contains unproven content #{child}")]

            true ->
              []
          end
        end)

      true ->
        []
    end
  end

  defp modify_conflicts(journal, entry, path, stat) do
    cond do
      stat.type != "file" ->
        [conflict_message(entry, "shared target exists as #{stat.type}")]

      # Shared-target fragment integrity is validated before the backend
      # runs, so a later modifier conflict cannot follow earlier writes.
      entry["fragments"] ->
        applied = (journal && journal["fragments"] && journal["fragments"][entry["target"]]) || []
        recorded = Map.new(applied, fn fragment -> {fragment["id"], fragment} end)

        case ShellProgram.validate_target(path, entry["fragments"], recorded) do
          {:error, reason} -> [conflict_message(entry, reason)]
          {:ok, nil} -> []
        end

      true ->
        []
    end
  end

  defp owned_target_conflicts(home, journal, entry, excused, adopt) do
    target = entry["target"]
    recorded = journal && journal["targets"] && journal["targets"][target]

    cond do
      recorded && MapSet.member?(excused, target) ->
        # The interrupted attempt that wrote this target belongs to THIS
        # plan's generation: its pending record proves the on-disk state
        # is the plan's own, so equality against the older successful
        # generation cannot hold and must not block the retry.
        []

      recorded ->
        fingerprint = Journal.target_fingerprint(home, target)

        if fingerprint == nil or fingerprint["type"] != recorded["type"] or
             fingerprint["sha256"] != recorded["sha256"] or fingerprint["link"] != recorded["link"] or
             fingerprint["mode"] != recorded["mode"] do
          [conflict_message(entry, "target changed since the last successful apply")]
        else
          []
        end

      entry["expected"] ->
        fingerprint = Journal.target_fingerprint(home, target)

        if fingerprint["type"] != entry["expected"]["type"] or
             fingerprint["sha256"] != entry["expected"]["sha256"] or
             fingerprint["link"] != entry["expected"]["link"] or
             fingerprint["mode"] != entry["expected"]["mode"] do
          [
            conflict_message(
              entry,
              "first adoption of an existing unrecorded target differing in type, mode, content or link; " <>
                "inspect it and remove or back it up explicitly"
            )
          ]
        else
          []
        end

      true ->
        orphan_conflicts(home, entry, adopt)
    end
  end

  # The un-owned orphan class: backend-rendered state with no journal
  # record. The probe is read-only and runs in BOTH modes — the plain
  # refusal carries the per-target verdict so one report is actionable — and
  # the operator-gated `"adopt"` context treats a verified target as
  # adopted: the apply's own claim step then records its ownership.
  defp orphan_conflicts(home, entry, adopt) do
    message =
      case probe(home, entry) do
        :match when adopt ->
          nil

        :match ->
          conflict_message(
            entry,
            "backend-rendered target exists without an owned record " <>
              "(probe: the on-disk state matches what the plan renders; the operator-gated adoption door is `workstation apply --adopt`)"
          )

        {:differ, verdict} ->
          conflict_message(
            entry,
            "backend-rendered target exists without an owned record " <>
              "(probe: #{verdict}; recover explicitly — the guarded-apply recovery runbook)"
          )

        {:unverifiable, verdict} ->
          conflict_message(
            entry,
            "backend-rendered target exists without an owned record " <>
              "(probe: not verifiable before the backend renders — #{verdict}; recover explicitly — the guarded-apply recovery runbook)"
          )
      end

    if message, do: [message], else: []
  end

  # Read-only content-identity probe: does the on-disk target equal the
  # state this plan renders? Nil plan attributes are wildcards — the
  # backend does not manage that attribute for the entry (symlinks carry no
  # mode, directories no bytes). Template entries render only inside the
  # backend, so their rendered form cannot exist before it runs.
  defp probe(home, entry) do
    if entry["template"] do
      {:unverifiable, "the entry renders through the backend template pass"}
    else
      probe_live(Journal.target_fingerprint(home, entry["target"]), entry)
    end
  end

  defp probe_live(nil, _entry), do: {:differ, "the on-disk target is unreadable or of an unsupported type"}

  defp probe_live(live, entry) do
    cond do
      live["type"] != entry["type"] ->
        {:differ, "on-disk type is #{live["type"]}, the plan renders #{entry["type"]}"}

      entry["type"] == "file" and live["sha256"] != EngineState.sha256(entry["bytes"]) ->
        {:differ, "on-disk content differs from the rendered bytes"}

      entry["type"] == "link" and live["link"] != entry["link"] ->
        {:differ, "on-disk link is #{live["link"]}, the plan renders #{entry["link"]}"}

      entry["mode"] != nil and live["mode"] != entry["mode"] ->
        {:differ, "on-disk mode is #{live["mode"]}, the plan renders #{entry["mode"]}"}

      true ->
        :match
    end
  end

  defp check_removal(home, journal, removal) do
    target = removal["target"]
    recorded = journal && journal["targets"] && journal["targets"][target]
    present = EngineState.lstat(EngineState.join_home(home, target)) != nil

    if present do
      # Package remove recipes operate on recorded ownership only: an
      # existing target that was never journaled is never destructively
      # adopted by a removal declaration.
      unless recorded do
        ["removal of #{target} conflicts: it exists but was never recorded as owned"]
      else
        fingerprint = Journal.target_fingerprint(home, target)

        unless fingerprint != nil and fingerprint["type"] == recorded["type"] and
                 fingerprint["sha256"] == recorded["sha256"] and fingerprint["link"] == recorded["link"] and
                 fingerprint["mode"] == recorded["mode"] do
          ["removal of #{target} conflicts: the target changed since the last successful apply"]
        else
          []
        end
      end
    else
      []
    end
  end
end
