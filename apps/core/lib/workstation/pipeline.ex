defmodule Workstation.Pipeline.Run do
  @moduledoc """
  The pipeline accumulator: one %Run{} flows through the named stages and
  every stage contributes its field — `discover` the catalog, `resolve` the
  graph, `compose` the plan. The read pipeline is the whole pipeline: the
  write stages retired with the engine's write plane (nix owns mutation).
  Nothing else in the engine threads evaluation state by parameter.
  """

  defstruct input: nil,
            home: nil,
            opts: %{},
            catalog: nil,
            graph: nil,
            plan: nil

  @type t :: %__MODULE__{
          input:
            nil
            | {:native, Workstation.Core.Catalog.t()}
            | {:file, map()}
            | {:collector, (-> {:ok, Workstation.Core.Catalog.t()} | {:error, term()}) | nil},
          home: String.t() | nil,
          opts: map(),
          catalog: Workstation.Core.Catalog.t() | nil,
          graph: Workstation.Core.Graph.t() | nil,
          plan: Workstation.Core.Source.t() | nil
        }
end

defmodule Workstation.Pipeline.CollectFailed do
  @moduledoc """
  Raised when a catalog collector refuses; the caller surfaces it with its
  own wire coding distinct from engine errors.
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

      discover -> resolve -> compose

  Kernel modules implement the stages (discovery, resolution, composition).
  A CLI verb is a prefix of this list: `status` runs to `resolve`, `plan`
  to `compose` (`verb_depth/1`). The write stages (check, stage, anchor,
  interpret, claim, verify) retired with the engine's write plane: mutation
  is the nix substrate's `workstation-switch` drivers. The typed effects
  view (`effects/1`) remains as the read-side projection of the declared
  mutation program the manifests carry — nothing executes it here.
  """

  alias Workstation.Core.{Catalog, Graph, Source}
  alias Workstation.Core.Contracts.Contract
  alias Workstation.Pipeline.CollectFailed

  @stage_order [:discover, :resolve, :compose]

  # CLI verbs are pipeline prefixes: a verb's depth is the last stage its
  # evaluation runs.
  @verb_depths %{status: :resolve, plan: :compose}

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

  @doc "The pipeline depth of one evaluation verb (status/plan)."
  @spec verb_depth(atom()) :: atom()
  def verb_depth(verb) when is_atom(verb) do
    Map.fetch!(@verb_depths, verb)
  end

  @doc "The evaluation verbs and their depths — every verb is a pipeline prefix."
  @spec verbs() :: %{atom() => atom()}
  def verbs, do: @verb_depths

  @doc """
  Reduce the stage prefix ending at `to` (default: the full list) over `run`.
  The evaluation stays pure — no journal, no filesystem probing — so golden
  replay is a function of its input bytes.
  """
  @spec run(Workstation.Pipeline.Run.t(), atom()) :: Workstation.Pipeline.Run.t()
  def run(%Workstation.Pipeline.Run{} = run, to \\ :compose) do
    stages_upto(to) |> Enum.reduce(run, &apply_stage/2)
  end

  @doc """
  The plan's typed mutation program as DECLARED data: every discovered
  contract's share of the plan, validated and ordered
  `{phase, contract, target}` — per-target effects first, the single
  generation-apply effect last. Pure; this is the read-side projection the
  wire carries (the recorded plan shape declares its effects). Nothing
  executes it — the nix substrate's switch drivers own the mutation.
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
    # not an ordering question.
    apply_effects = Enum.filter(effects, &(&1.phase == :apply))
    length(apply_effects) <= 1 || raise(ArgumentError, "more than one apply-phase effect declared")

    Enum.sort_by(effects, &{phase_rank(&1.phase), &1.contract, &1[:target] || ""})
  end

  # --- stages ---

  defp apply_stage(name, run), do: stage(name).(run)

  defp stage(:discover), do: &discover/1
  defp stage(:resolve), do: &resolve/1
  defp stage(:compose), do: &compose/1

  # The catalog: the native live envelope, a recorded golden envelope, or a
  # sandbox collector (tests). Collection failure is a distinct exception so
  # callers can keep their surface coding; engine errors raise raw.
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

  # The composition stays pure (replay purity: no journal, no filesystem
  # probing) — the declared desired state, nothing else.
  defp compose(%Workstation.Pipeline.Run{graph: graph} = run) do
    %{run | plan: Source.plan(%{graph: graph})}
  end

  # --- effect helpers ---

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
end
