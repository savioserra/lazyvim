defmodule Workstation.Pipeline.Run do
  @moduledoc """
  The pipeline accumulator: one %Run{} flows through the named stages and
  every stage contributes its field — `discover` the catalog, `resolve` the
  graph, `compose` the plan (stamping the journal baseline in apply mode),
  `check` the preconditions, `stage` the published generation directory,
  `anchor` the pending journal record, `interpret` the typed effects, `claim`
  the applied-target ownership and `verify` the generation. Nothing else in
  the engine threads mutation state by parameter.
  """

  defstruct input: nil,
            mode: :read,
            home: nil,
            opts: %{},
            catalog: nil,
            graph: nil,
            journal: nil,
            plan: nil,
            directory: nil,
            effects: []

  @type t :: %__MODULE__{
          input:
            nil
            | {:native, Workstation.Core.Catalog.t()}
            | {:file, map()}
            | {:collector, (-> {:ok, Workstation.Core.Catalog.t()} | {:error, term()}) | nil},
          mode: :read | :apply,
          home: String.t() | nil,
          opts: map(),
          catalog: Workstation.Core.Catalog.t() | nil,
          graph: Workstation.Core.Graph.t() | nil,
          journal: map() | nil,
          plan: Workstation.Core.Source.t() | nil,
          directory: String.t() | nil,
          effects: [map()]
        }
end

defmodule Workstation.Pipeline.CollectFailed do
  @moduledoc """
  Raised when a catalog collector refuses: `Workstation.Pipeline.composed_plan/2`
  surfaces it as `{:error, {:collect_failed, reason}}` so every mutation
  surface keeps its own wire coding distinct from engine errors.
  """

  defexception [:reason]

  @impl true
  def message(exception), do: "plan collection failed: #{inspect(exception.reason)}"
end

defmodule Workstation.Pipeline do
  @moduledoc """
  Layer: kernel. The kernel law: this module names no package, no backend and
  no consumer — it speaks only contracts and shapes (docs/architecture.md,
  "Module hierarchy & moduledoc conventions").

  The pipeline law: the engine is ONE named stage list reduced over a
  `%Workstation.Pipeline.Run{}` accumulator —

      discover -> resolve -> compose -> check -> stage -> anchor ->
        interpret -> claim -> verify

  Kernel modules implement stages (discovery, resolution, composition,
  preconditions, staging, the journal anchor, generation verification); the
  effect execution itself is a FOLD over the plan's typed effects, dispatched
  through discovered `Workstation.Core.Contracts.Contract` implementations —
  never named here. A CLI verb is a prefix of this list: `status` runs to
  `resolve`, `plan`/`diff` to `compose`, `apply` to `verify`
  (`verb_depth/1`).

  Ordering is the invariant, not a preference, and the stage order IS the
  ordering: preconditions run BEFORE any write (a stale plan or an intervening
  home edit must never reach the fold), the pending attempt record anchors
  BEFORE any effect runs (a crashed apply must leave a recoverable anchor,
  and an unresolved attempt is surfaced by the next generation's
  preconditions), the applied provenance record lands only AFTER every effect
  succeeded, and the generation directory is re-verified after the fold — the
  effects mutate the home, never the generation, and a damaged generation
  after an apply is a corruption signal, not something to accept silently.

  The effects fold (`interpret`) preserves the execution order the contracts
  declare: per-target effects first (a pinned artifact installs before the
  staged generation is applied), the single generation-apply effect last. A
  failed effect records `journal/failed/` and the pending record stays —
  recovery is conflict-aware through the journal, never a blind replay.

  Re-applying the identical desired generation is an idempotent no-op by
  preconditions (the journal's current generation matches, so the plan is not
  stale): the effects re-run, the applied record advances its revision, and
  the per-target fingerprints stay byte-identical because the targets already
  matched the generation.

  Every write is serialized by the caller (the daemon's apply orchestrator
  holds the same `<state_root>/apply.lock` the one-shot apply always took);
  this module is lock-free by design so any future driver inherits the same
  serialization contract. Composition (`composed_plan/2`) happens OUTSIDE the
  lock on every surface; `execute/2` is the locked continuation from `check`.
  """

  alias Workstation.Core.{Catalog, EngineState, Graph, Journal, Preconditions, Provisioner, Source}
  alias Workstation.Core.Contracts.Contract
  alias Workstation.Pipeline.CollectFailed

  @stage_order [:discover, :resolve, :compose, :check, :stage, :anchor, :interpret, :claim, :verify]

  # CLI verbs are pipeline prefixes: a verb's depth is the last stage its
  # evaluation runs. `apply` is the full list (through the composition and
  # locked-continuation split every mutation surface already follows).
  @verb_depths %{status: :resolve, plan: :compose, diff: :compose, apply: :verify}


  @doc "The named stage list, in reduction order — the engine's invariant ordering."
  @spec stages() :: [atom()]
  def stages, do: @stage_order

  @doc "The stage list prefix whose last stage is `to`."
  @spec stages_upto(atom()) :: [atom()]
  def stages_upto(to) do
    index = Enum.find_index(@stage_order, &(&1 == to))
    index || raise(ArgumentError, "unknown pipeline stage #{inspect(to)}")
    Enum.take(@stage_order, index + 1)
  end

  @doc "The pipeline depth of one evaluation verb (status/plan/diff/apply)."
  @spec verb_depth(atom()) :: atom()
  def verb_depth(verb) when is_atom(verb) do
    Map.fetch!(@verb_depths, verb)
  end

  @doc "The evaluation verbs and their depths — every verb is a pipeline prefix."
  @spec verbs() :: %{atom() => atom()}
  def verbs, do: @verb_depths

  @doc """
  Reduce the stage prefix ending at `to` (default: the full list) over `run`.
  Read verbs (`mode: :read`) stay pure — no journal, no filesystem probing —
  so golden replay is a function of its input bytes.
  """
  @spec run(Workstation.Pipeline.Run.t(), atom()) :: Workstation.Pipeline.Run.t()
  def run(%Workstation.Pipeline.Run{} = run, to \\ :verify) do
    stages_upto(to) |> Enum.reduce(run, &apply_stage/2)
  end

  @doc """
  The composition boundary every mutation surface shares: the live native
  catalog (or a sandbox `collect` — a zero-arity callable returning
  `{:ok, %Catalog{}}`), the ordered graph, the journal-stamped baseline and
  the removal activation. Runs the pipeline to `compose` in apply mode.
  Errors keep their cause explicit so each surface can apply its own wire
  coding: `{:error, {:collect_failed, reason}}` for catalog collection
  failures, `{:error, message}` for engine preconditions' verbatim
  `ArgumentError` text.
  """
  @spec composed_plan(String.t(), (-> {:ok, Catalog.t()} | {:error, term()}) | nil) ::
          {:ok, Source.t()} | {:error, {:collect_failed, term()}} | {:error, String.t()}
  def composed_plan(home, collect \\ nil) do
    case run(%Workstation.Pipeline.Run{input: {:collector, collect}, mode: :apply, home: home}, :compose) do
      %{plan: plan} -> {:ok, plan}
    end
  rescue
    error in [CollectFailed] -> {:error, {:collect_failed, error.reason}}
    error in [ArgumentError] -> {:error, Exception.message(error)}
  end

  @doc """
  Execute one plan's mutation against the target home and return its
  generation identifier — the locked continuation from `check` through
  `verify` (the caller composed the plan outside the lock and holds the apply
  lock). `opts` carry `"home"` (defaults to the target home), the optional
  `"requested_generation"` (when present it must equal the plan's generation,
  turning a client that asks for a different generation than the built plan
  into the same stale-plan refusal as any other divergence) and the optional
  `"fetch"` (injected download fetch, tests). Raises `ArgumentError` on stale
  plans, conflicts, effect failures and invariant violations.
  """
  @spec execute(Source.t(), map()) :: String.t()
  def execute(%Source{} = plan, opts \\ %{}) do
    run = %Workstation.Pipeline.Run{
      mode: :apply,
      plan: plan,
      home: opts["home"] || EngineState.home(),
      opts: opts
    }

    %{plan: plan} = Enum.reduce(stages_from(:check), run, &apply_stage/2)
    plan.generation
  end

  @doc """
  The plan's typed mutation program: every discovered contract's declared
  share of the plan, validated and ordered `{phase, contract, target}` —
  per-target effects first, the single generation-apply effect last. Pure;
  shared by the interpret fold and the wire projections (the recorded plan
  shape declares its effects).
  """
  @spec effects(Source.t()) :: [map()]
  def effects(%Source{} = plan) do
    effects =
      Contract.Discover.contracts()
      |> Enum.flat_map(fn contract ->
        contract.plan_effect(plan, %{}) |> Enum.map(&declared_effect(&1, contract))
      end)

    # The apply phase is the staged generation applied exactly once, after
    # every per-target effect — more than one declarer is an invariant break,
    # not a fold order question.
    apply_effects = Enum.filter(effects, &(&1.phase == :apply))
    length(apply_effects) <= 1 || raise(ArgumentError, "more than one apply-phase effect declared")

    Enum.sort_by(effects, &{phase_rank(&1.phase), &1.contract, &1[:target] || ""})
  end

  # --- stages ---

  defp apply_stage(name, run), do: stage(name).(run)

  defp stage(:discover), do: &discover/1
  defp stage(:resolve), do: &resolve/1
  defp stage(:compose), do: &compose/1
  defp stage(:check), do: &check/1
  defp stage(:stage), do: &stage_generation/1
  defp stage(:anchor), do: &anchor/1
  defp stage(:interpret), do: &interpret/1
  defp stage(:claim), do: &claim/1
  defp stage(:verify), do: &verify/1

  defp stages_from(from), do: Enum.drop_while(@stage_order, &(&1 != from))

  # The catalog: the native live envelope, a recorded golden envelope, or a
  # sandbox collector (tests). Collection failure is a distinct exception so
  # `composed_plan/2` can keep its surface coding; engine errors raise raw.
  defp discover(%Workstation.Pipeline.Run{input: input} = run) do
    catalog =
      case input do
        nil -> Catalog.live(run.home)
        {:native, catalog} -> catalog
        {:file, envelope} -> Catalog.load(envelope)
        {:collector, nil} -> Catalog.live(run.home)
        {:collector, fun} ->
          case fun.() do
            {:ok, catalog} -> catalog
            {:error, reason} -> raise CollectFailed, reason: reason
          end
      end

    %{run | catalog: catalog}
  end

  defp resolve(%Workstation.Pipeline.Run{catalog: catalog} = run) do
    %{run | graph: Graph.order(%{host: catalog.host, specifications: catalog.packages})}
  end

  # Read mode stays pure (replay purity: no journal, no filesystem); apply
  # mode is the production composition boundary — the plan records the
  # journal state it was composed against and declared removals activate
  # exactly here, where journal and destination home are both readable.
  defp compose(%Workstation.Pipeline.Run{mode: :read, graph: graph} = run) do
    %{run | plan: Source.plan(%{graph: graph})}
  end

  defp compose(%Workstation.Pipeline.Run{mode: :apply, home: home, graph: graph} = run) do
    journal = Journal.applied(Path.join([home | EngineState.state_components()]))

    plan =
      %{graph: graph}
      |> Source.plan()
      |> Source.with_baseline(journal)
      |> Source.activate_removals(journal, home)

    %{run | journal: journal, plan: plan}
  end

  # Preconditions run inside the caller's lock BEFORE any write. The anchor's
  # apply path guards all engine roots up front, so the guarded tree exists
  # before any precondition or record runs.
  defp check(%Workstation.Pipeline.Run{} = run) do
    :ok = EngineState.ensure_roots!(run.home)

    case run.opts["requested_generation"] do
      nil -> :ok
      requested when requested == run.plan.generation -> :ok

      requested ->
        raise ArgumentError,
              "stale plan: requested generation #{inspect(requested)} does not match the built plan generation " <>
                "#{inspect(run.plan.generation)}; rebuild the plan"
    end

    Preconditions.check(precondition_plan(run.plan), %{"home" => run.home})
    run
  end

  # The staged generation: content-addressed, written privately, verified
  # into place before anything anchors or runs.
  defp stage_generation(%Workstation.Pipeline.Run{} = run) do
    %{run | directory: Provisioner.publish(run.plan, %{"home" => run.home})}
  end

  # The pending attempt record lands BEFORE the effects fold: a crashed apply
  # must leave a recoverable anchor, and the record already carries every
  # target the fold may touch.
  defp anchor(%Workstation.Pipeline.Run{} = run) do
    plan = run.plan

    Journal.write_pending(run.home, %{
      "generation" => plan.generation,
      "at" => System.system_time(:second),
      "pid" => :os.getpid(),
      "entries" => length(plan.entries),
      "targets" => Enum.map(plan.entries, & &1.target) ++ Enum.map(plan.downloads, & &1.target)
    })

    run
  end

  # The effects fold: the plan's typed program run through its discovered
  # contracts. A failed effect records journal/failed and the pending record
  # stays — recovery is conflict-aware through the journal, never a blind
  # replay. The fetch is injectable for tests; production fetches HTTPS.
  defp interpret(%Workstation.Pipeline.Run{} = run) do
    effects = effects(run.plan)
    ctx = effect_ctx(run)

    try do
      Enum.each(effects, fn effect ->
        contract = Contract.Discover.lookup!(effect.contract)
        :ok = contract.run_effect(effect, ctx)
      end)
    rescue
      error ->
        Journal.write_failed(run.home, run.plan.generation, error)
        reraise error, __STACKTRACE__
    end

    %{run | effects: effects}
  end

  # The applied record is the ownership claim every later check trusts, so
  # the fingerprints are taken from the ACTUAL home after the fold: an effect
  # that did not produce its target is a hard failure, never recorded.
  defp claim(%Workstation.Pipeline.Run{} = run) do
    plan = run.plan
    ctx = effect_ctx(run)

    targets =
      Enum.reduce(run.effects, %{}, fn effect, acc ->
        contract = Contract.Discover.lookup!(effect.contract)
        Map.merge(acc, contract.fingerprint(effect, ctx))
      end)

    Journal.record_applied(run.home, plan.generation, targets, plan.fragments_journal, plan.manifest, source_index(plan))
    :ok = Journal.clear_pending(run.home)
    run
  end

  # The generation directory is re-verified after the fold: the effects
  # mutate the home, never the generation, and damage after an apply is a
  # corruption signal.
  defp verify(%Workstation.Pipeline.Run{} = run) do
    true = Provisioner.verify_generation(run.directory, run.plan.manifest)
    run
  end

  # --- effect helpers ---

  defp effect_ctx(%Workstation.Pipeline.Run{} = run) do
    %{home: run.home, plan: run.plan, directory: run.directory, fetch: run.opts["fetch"]}
  end

  defp declared_effect(effect, contract) do
    Map.get(effect, :contract) == contract.id() ||
      raise(ArgumentError,
            "effect names contract #{inspect(Map.get(effect, :contract))} but was declared by #{inspect(contract.id())}")

    effect[:phase] in [:target, :apply] ||
      raise(ArgumentError, "effect for contract #{contract.id()} has invalid phase #{inspect(effect[:phase])}")

    is_atom(effect[:kind]) ||
      raise(ArgumentError, "effect for contract #{contract.id()} has no kind")

    effect
  end

  defp phase_rank(:target), do: 0
  defp phase_rank(:apply), do: 1

  # --- shape projections (string-keyed views the checks and the journal
  # read; the anchor's schema, verbatim) ---

  # Preconditions bind to the string-keyed plan shape; this projection is the
  # executor's view of the in-process plan (the same fields the read side
  # projects to the wire, restricted to what the checks read). Shell
  # fragments are projected id/marker/body because the precondition checks
  # (and the shared-target validator) read exactly those string keys.
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

  defp fragments_view(nil), do: nil

  defp fragments_view(fragments) do
    Enum.map(fragments, fn fragment ->
      %{"id" => fragment.id, "marker" => fragment.marker, "body" => fragment.body}
    end)
  end
end
