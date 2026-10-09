defmodule Workstation.Core.Contracts.Contract do
  @moduledoc """
  The effect contract: a thing that mutates the home through typed effects.

  Where `Workstation.Core.Contracts.Provider` is the PLAN-time composition
  handshake (specs -> source records), this is the APPLY-time handshake: a
  contract declares how its share of a built plan becomes a list of typed,
  ordered effects, how one effect executes at the apply boundary, and how its
  applied targets are claimed into the journal. The pipeline's interpret
  stage folds a plan's effects through discovered contracts — the kernel
  never names an implementation (implementor policy: implementations live in
  the backend and contract modules of the engine, and `Contract.Discover`
  finds them by behaviour conformance).

  Effect shape (atom-keyed internal view; the wire projection stringifies):

      %{contract: id, kind: atom, phase: :target | :apply, ...}

  Ordering is part of the contract: the pipeline sorts collected effects by
  `{phase, contract, target}`, so every per-target effect (:target — e.g. a
  pinned-artifact install) runs before the single generation-apply effect
  (:apply). The apply phase carries at most one effect — the staged
  generation is applied exactly once, after every target mutation.
  """

  @doc "The wire contract id this implementation owns (matches its provider id)."
  @callback id() :: String.t()

  @doc "Validate one declared spec. Raises `ArgumentError` on invalid shape."
  @callback validate_spec(term()) :: :ok

  @doc """
  This contract's share of the plan's mutation program: the effects the
  built plan (a `Workstation.Core.Source.t()`) carries for this contract.
  Pure — no I/O, no execution.
  """
  @callback plan_effect(term(), map()) :: [map()]

  @doc """
  Execute one effect at the apply boundary. `ctx` carries `:home`, `:plan`,
  `:directory` (the staged generation) and `:fetch` (injected fetch, tests).
  Raises on failure; the pipeline anchors the failure in the journal.
  """
  @callback run_effect(map(), map()) :: :ok

  @doc """
  The applied-target ownership claim for one effect: `%{target => record}`
  computed from the ACTUAL home after the effect ran. An effect that did not
  produce exactly its declared outcome raises instead of recording.
  """
  @callback fingerprint(map(), map()) :: map()

  @doc """
  The verify seam (OPTIONAL — effect kinds whose ownership claim is not a
  file fingerprint report their own verification). Given one applied-target
  journal record, verify it against the ACTUAL home: `:ok` when the record
  still holds, `:unclaimed` when the record is not this contract's shape
  (the next discovered contract — or the default file-fingerprint
  verification — takes it), raising when the record FAILED verification.
  `ctx` carries `"home"` and `"target"`.
  """
  @callback verify_record(record :: map(), ctx :: map()) :: :ok | :unclaimed

  @doc """
  Every wire id this implementation owns — `[id/0]` unless the contract
  carries a second composition shape (chezmoi's data envelope is a second
  id of the same backend). Discovery publishes the full owned set, so the
  assembler and the golden-envelope reader derive their dispatch without
  naming a single id.
  """
  @callback ids() :: [String.t()]

  @doc """
  Denormalize one recorded (string-keyed) golden-envelope spec back to the
  atom-keyed declared shape, so a replay compares equal to the native
  declaration. `ctx` carries the golden-envelope context the catalog reader
  composes with: `:package_id` (error attribution), `:assets` (the recorded
  asset bodies), `:live_home` and `:canonical_home` (the live re-rooting
  bracket). Raises `ArgumentError` on an invalid shape. OPTIONAL: a
  contract without a recorded shape simply does not implement it — the
  golden-envelope reader fails closed on the dispatch and names the
  provider.
  """
  @callback from_recorded(spec :: map(), ctx :: map()) :: term()
  @optional_callbacks [verify_record: 2, ids: 0, from_recorded: 2]
end


defmodule Workstation.Core.Contracts.Contract.Discover do
  @moduledoc """
  Runtime effect-contract discovery, mirroring
  `Workstation.Core.Contracts.Provider.Discover`: the engine's mutation
  surface is whatever conforming `Workstation.Core.Contracts.Contract`
  modules the code path carries — never a hand-written registry, and the
  kernel never names one.

  Candidates come from `:code.all_available/0` narrowed to the
  `Workstation.*` namespaces (contracts are engine-side: backends and the
  contract modules themselves; a package may also implement one from its own
  namespace), test-tree beams are excluded by recorded source path, and
  conformance requires the behaviour attribute plus the full callback set.
  The pipeline itself is the shared
  `Workstation.Core.Contracts.Discovery` helper — this module supplies
  only the effect-contract parameterization.
  """

  @callbacks [id: 0, validate_spec: 1, plan_effect: 2, run_effect: 2, fingerprint: 2]

  @doc "The discovered effect-contract modules, sorted by module name."
  @spec contracts() :: [module()]
  def contracts do
    Workstation.Core.Contracts.Discovery.modules(%{
      # The engine-owned effect contracts publish through the code-path
      # namespace arm; package-owned ones arrive via the tree walk.
      namespace: "Elixir.Workstation.",
      behaviour: Workstation.Core.Contracts.Contract,
      callbacks: @callbacks,
      label: "effect-contract"
    })
  end

  @doc """
  Wire id -> implementing module, from the discovered set. A contract may
  own several wire ids (the optional `ids/0` callback) — each maps to its
  implementor.
  """
  @spec by_id() :: %{String.t() => module()}
  def by_id do
    contracts()
    |> Enum.flat_map(fn module ->
      ids = if function_exported?(module, :ids, 0), do: module.ids(), else: [module.id()]
      Enum.map(ids, &{&1, module})
    end)
    |> Map.new()
  end

  @doc "Look up the implementing module for one contract id."
  @spec lookup(String.t()) :: {:ok, module()} | :error
  def lookup(id) when is_binary(id) do
    case Map.fetch(by_id(), id) do
      {:ok, module} -> {:ok, module}
      :error -> :error
    end
  end

  def lookup(_other), do: :error

  @doc "Look up the implementing module for one contract id, failing closed."
  @spec lookup!(String.t()) :: module()
  def lookup!(id) when is_binary(id) do
    case lookup(id) do
      {:ok, module} -> module
      :error -> raise ArgumentError, "no discovered contract implements #{inspect(id)}"
    end
  end
end
