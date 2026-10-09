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
  backend mutation. The plan is bound to the journal revision it was built
  against. This module never mutates anything: conflicts raise, and the
  engine stays the sole writer of home and journal state.
  """

  alias Workstation.Core.EngineState
  alias Workstation.Core.Journal
  alias Workstation.Core.ShellProgram

  defp is_within(target, ancestor) do
    target == ancestor or String.starts_with?(target, ancestor <> "/")
  end

  defp conflict(entry, message) do
    raise(ArgumentError,
      "workstation apply conflict at #{entry["target"]} (owner #{Enum.join(entry["attribution"] || [], ",")}): #{message}"
    )
  end

  @doc """
  Check every planned mutation against the actual home. `context` may pin
  `"home"`, the applied journal record (`"journal"`) and `"pending"` records
  for tests; nil derives them from the environment, exactly like the anchor.
  Returns :ok or raises ArgumentError with the anchored conflict message.
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

    desired_targets = MapSet.new(plan["entries"], & &1["target"])

    # Unresolved partial attempts are never silently forgotten: when the
    # desired generation changed, any target the attempt touched that is
    # neither proven owned (journal) nor still desired must be recovered
    # explicitly before a new generation may apply.
    Enum.each(pending, fn record ->
      if record["generation"] != plan["generation"] do
        Enum.each(record["targets"] || [], fn target ->
          owned = journal && journal["targets"] && journal["targets"][target]

          if owned == nil and not MapSet.member?(desired_targets, target) and
               EngineState.lstat(EngineState.join_home(home, target)) != nil do
            raise(ArgumentError,
              "workstation apply conflict: unresolved partial attempt for generation #{record["generation"]} " <>
                "touched #{target}, which is neither recorded as owned nor desired; inspect the journal and recover explicitly"
            )
          end
        end)
      end
    end)

    Enum.each(plan["entries"], fn entry ->
      check_entry(home, journal, entry)
    end)

    Enum.each(plan["removals"] || [], fn removal ->
      check_removal(home, journal, removal)
    end)

    :ok
  end

  # Never write through a symlinked ancestor into unrelated state.
  defp check_ancestors(home, target) do
    ancestor = ancestor_of(target)

    if ancestor do
      ancestor_stat = EngineState.lstat(EngineState.join_home(home, ancestor))

      unless ancestor_stat == nil or ancestor_stat.type != "link" do
        raise(ArgumentError, "refusing to write through symlinked ancestor #{ancestor} for #{target}")
      end

      check_ancestors(home, ancestor)
    end
  end

  defp ancestor_of(target) do
    case Regex.run(~r{\A(.*)/[^/]+\z}, target) do
      [_all, ancestor] -> ancestor
      _other -> nil
    end
  end

  defp check_entry(home, journal, entry) do
    target = entry["target"]
    path = EngineState.join_home(home, target)
    stat = EngineState.lstat(path)
    check_ancestors(home, target)

    cond do
      entry["operation"] == "directory" ->
        if stat && stat.type != "directory", do: conflict(entry, "target exists as #{stat.type}")

        if entry["exact"] && stat do
          # Exact management prunes anything unknown inside the target:
          # adoption requires complete proven ownership of the existing
          # contents, otherwise it fails closed.
          journal_targets = (journal && journal["targets"]) || %{}

          owned =
            journal_targets
            |> Map.keys()
            |> MapSet.new(& &1)
            |> MapSet.filter(fn journal_target -> is_within(journal_target, target) end)

          Enum.each(File.ls!(path), fn child ->
            child_stat = EngineState.lstat(Path.join(path, child))

            if child_stat && child_stat.type == "directory" do
              conflict(entry, "exact directory contains unproven subdirectory #{child}")
            end

            unless MapSet.member?(owned, target <> "/" <> child) do
              conflict(entry, "exact directory contains unproven content #{child}")
            end
          end)
        end

      stat == nil ->
        # absent targets are adoptable
        :ok

      entry["operation"] == "modify" ->
        if stat.type != "file", do: conflict(entry, "shared target exists as #{stat.type}")

        # Shared-target fragment integrity is validated before the backend
        # runs, so a later modifier conflict cannot follow earlier writes.
        if entry["fragments"] do
          applied = (journal && journal["fragments"] && journal["fragments"][target]) || []
          recorded = Map.new(applied, fn fragment -> {fragment["id"], fragment} end)

          case ShellProgram.validate_target(path, entry["fragments"], recorded) do
            {:error, reason} -> conflict(entry, reason)
            {:ok, nil} -> :ok
          end
        end

      true ->
        recorded = journal && journal["targets"] && journal["targets"][target]

        if recorded do
          fingerprint = Journal.target_fingerprint(home, target)

          if fingerprint == nil or fingerprint["type"] != recorded["type"] or
               fingerprint["sha256"] != recorded["sha256"] or fingerprint["link"] != recorded["link"] or
               fingerprint["mode"] != recorded["mode"] do
            conflict(entry, "target changed since the last successful apply")
          end
        else
          if entry["expected"] do
            fingerprint = Journal.target_fingerprint(home, target)

            if fingerprint["type"] != entry["expected"]["type"] or
                 fingerprint["sha256"] != entry["expected"]["sha256"] or
                 fingerprint["link"] != entry["expected"]["link"] or
                 fingerprint["mode"] != entry["expected"]["mode"] do
              conflict(
                entry,
                "first adoption of an existing unrecorded target differing in type, mode, content or link; " <>
                  "inspect it and remove or back it up explicitly"
              )
            end
          else
            conflict(entry, "backend-rendered target exists without an owned record")
          end
        end
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
        raise(ArgumentError, "removal of #{target} conflicts: it exists but was never recorded as owned")
      end

      fingerprint = Journal.target_fingerprint(home, target)

      unless fingerprint != nil and fingerprint["type"] == recorded["type"] and
               fingerprint["sha256"] == recorded["sha256"] and fingerprint["link"] == recorded["link"] and
               fingerprint["mode"] == recorded["mode"] do
        raise(ArgumentError, "removal of #{target} conflicts: the target changed since the last successful apply")
      end
    end
  end
end
