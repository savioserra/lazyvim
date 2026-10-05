defmodule Workstation.Core.ApplyEngine do
  @moduledoc """
  The one-shot generation pipeline: preconditions, staged publish, guarded
  journal records, backend apply and post-apply verification. Parity anchor:
  `M.apply` plus `check_preconditions` in
  `workstation/lua/workstation/provisioner.lua`.

  Ordering is the invariant, not a preference: preconditions run inside the
  apply lock BEFORE any write (a stale plan or an intervening home edit must
  never reach the backend), the pending attempt record lands BEFORE the
  backend runs (a crashed apply must leave a recoverable anchor, and an
  unresolved attempt is surfaced by the next generation's preconditions), the
  applied provenance record lands only AFTER the backend succeeded, and the
  generation directory is re-verified after the backend ran — the backend
  mutates the home, never the generation, and a damaged generation after an
  apply is a corruption signal, not something to accept silently.

  Re-applying the identical desired generation is an idempotent no-op by
  preconditions (the journal's current generation matches, so the plan is not
  stale): the backend re-runs, the applied record advances its revision, and
  the per-target fingerprints stay byte-identical because the targets already
  matched the generation. A failed backend run is recorded under
  `journal/failed/` and the pending record stays — recovery is
  conflict-aware through the journal, never a blind replay.

  Every write is serialized by the caller (the daemon's apply orchestrator
  holds the same `<state_root>/apply.lock` the Lua one-shot apply takes);
  this module itself is lock-free by design so any future driver inherits
  the same serialization contract.
  """

  alias Workstation.Core.{EngineState, Journal, Preconditions, Provisioner, Source}

  @doc """
  Execute one plan against the target home and return its generation
  identifier. `opts` carry `"home"` (defaults to the target home) and the
  optional `"requested_generation"` — when present it must equal the plan's
  generation, turning a client that asks for a different generation than the
  built plan into the same stale-plan refusal as any other divergence.
  Raises `ArgumentError` on stale plans, conflicts, backend failures and
  invariant violations; the caller owns the lock.
  """
  @spec execute(Source.t(), map()) :: String.t()
  def execute(%Source{} = plan, opts \\ %{}) do
    home = opts["home"] || EngineState.home()

    # The anchor's apply path guards all engine roots up front
    # (`state.lua ensure_roots`: root, generations, journal at 0700), so the
    # guarded tree exists before any precondition or record runs.
    :ok = EngineState.ensure_roots!(home)

    case opts["requested_generation"] do
      nil -> :ok
      requested when requested == plan.generation -> :ok

      requested ->
        raise ArgumentError,
              "stale plan: requested generation #{inspect(requested)} does not match the built plan generation " <>
                "#{inspect(plan.generation)}; rebuild the plan"
    end

    Preconditions.check(precondition_plan(plan), %{"home" => home})

    directory = Provisioner.publish(plan, %{"home" => home})

    Journal.write_pending(home, %{
      "generation" => plan.generation,
      "at" => System.system_time(:second),
      "pid" => :os.getpid(),
      "entries" => length(plan.entries),
      "targets" => Enum.map(plan.entries, & &1.target)
    })

    try do
      run_backend(home, directory)
    rescue
      error ->
        Journal.write_failed(home, plan.generation, error)
        reraise error, __STACKTRACE__
    end

    # The applied record is the ownership claim every later check trusts, so
    # the fingerprints are taken from the ACTUAL home after the backend ran:
    # an entry the backend did not produce is a hard failure, never recorded.
    targets = applied_fingerprints(plan, home)
    source_index = source_index(plan)

    Journal.record_applied(home, plan.generation, targets, plan.fragments_journal, plan.manifest, source_index)
    :ok = Journal.clear_pending(home)

    true = Provisioner.verify_generation(directory, plan.manifest)

    plan.generation
  end

  # The backend runs once per apply with the exact published generation as
  # `--source`; lifecycle scripts are excluded by the argv contract. The
  # backend's private state is pinned inside the target home (its own
  # boltdb lives under `<home>/.config/chezmoi`), never the operator's
  # ambient home. A missing or non-executable backend is a BACKEND FAILURE
  # (the documented ArgumentError contract), not a crash: it surfaces
  # through orchestrators that run this pipeline under a lock, where a raw
  # File.Error would kill the orchestrator process instead of failing the
  # operation.
  defp run_backend(home, directory) do
    [executable | args] = Provisioner.argv("apply", %{"source" => directory, "destination" => home})

    unless regular_executable?(executable) do
      raise ArgumentError,
            "chezmoi apply failed: backend missing or not executable at #{executable}; run bootstrap"
    end

    case System.cmd(executable, args, env: %{"HOME" => home, "WORKSTATION_HOME" => home}, stderr_to_stdout: false) do
      {_out, 0} ->
        :ok

      {out, code} ->
        raise ArgumentError, "chezmoi apply failed (exit #{code}): #{String.trim_trailing(out)}"
    end
  rescue
    error in [File.Error] ->
      raise ArgumentError, "chezmoi apply failed: #{Exception.message(error)}"
  end

  defp regular_executable?(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _other -> false
    end
  end

  # Preconditions bind to the string-keyed plan shape; this projection is the
  # executor's view of the in-process plan (the same fields the read side
  # projects to the wire, restricted to what the checks read). Shell
  # fragments are projected id/marker/body because the Lua-shaped checks
  # (and the shared-target validator) read exactly those string keys — the
  # in-process fragments are atom-keyed internals, and the journal's own
  # string-keyed fragment records come from fragments_journal, not here.
  defp precondition_plan(plan) do
    %{
      "generation" => plan.generation,
      "journal_revision" => plan.journal_revision,
      "baseline_generation" => plan.baseline_generation,
      "entries" =>
        Enum.map(plan.entries, fn entry ->
          %{
            "target" => entry.target,
            "operation" => entry.operation,
            "type" => entry.type,
            "attribution" => Map.get(entry, :attribution) || [entry.owner],
            "exact" => Map.get(entry, :exact),
            "fragments" => fragments_view(Map.get(entry, :fragments))
          }
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)
          |> Map.new()
        end),
      "removals" =>
        Enum.map(plan.removals, fn removal ->
          %{"target" => removal.target, "owner" => removal.owner}
        end)
    }
  end

  defp applied_fingerprints(plan, home) do
    Map.new(plan.entries, fn entry ->
      fingerprint = EngineState.target_fingerprint(home, entry.target)

      unless fingerprint,
        do: raise(ArgumentError, "apply did not produce target #{entry.target}")

      # The fingerprint fields and the provenance fields merge into ONE flat
      # record per target (the anchor's `fingerprint.owner = ...` table
      # mutation): readers compare the journal's target record directly
      # against a recomputed fingerprint, so nesting the fingerprint under a
      # key would make every re-apply look like an intervening edit.
      record =
        fingerprint
        |> Map.put("owner", entry.owner)
        |> Map.put("operation", entry.operation)
        # Journal-record parity: a nil fingerprint DROPS the
        # `source_fingerprint` key — fragment-composed modify entries have no
        # source fingerprint, and a stored nil would both corrupt canonical
        # JSON and diverge from the journal bytes already recorded on disk.
        |> maybe_put("source_fingerprint", Map.get(entry, :fingerprint))
        |> maybe_put("shared", Map.get(entry, :shared))

      {entry.target, record}
    end)
  end

  # The reverse-lookup index: which generated source name owns which target,
  # with the attribution and attributes a recovery decision needs.
  defp source_index(plan) do
    Map.new(plan.entries, fn entry ->
      record =
        %{
          "target" => entry.target,
          "owner" => entry.owner,
          "attribution" => Map.get(entry, :attribution),
          "type" => entry.type,
          "mode" => Map.get(entry, :mode),
          "link" => Map.get(entry, :link)
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      {entry.source_name, record}
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp fragments_view(nil), do: nil

  defp fragments_view(fragments) do
    Enum.map(fragments, fn fragment ->
      %{"id" => fragment.id, "marker" => fragment.marker, "body" => fragment.body}
    end)
  end
end
