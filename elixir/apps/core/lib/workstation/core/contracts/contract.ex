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
  """

  @namespace "Elixir.Workstation."

  @callbacks [id: 0, validate_spec: 1, plan_effect: 2, run_effect: 2, fingerprint: 2]

  @doc "The discovered effect-contract modules, sorted by module name."
  @spec contracts() :: [module()]
  def contracts do
    :code.all_available()
    |> Enum.flat_map(&candidates/1)
    |> Enum.uniq()
    |> Enum.filter(&namespace?/1)
    |> Enum.reject(&test_source?/1)
    |> Enum.filter(&conforming?/1)
    |> Enum.sort()
  end

  @doc "Contract id -> implementing module, from the discovered set."
  @spec by_id() :: %{String.t() => module()}
  def by_id do
    Map.new(contracts(), fn module -> {module.id(), module} end)
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

  defp candidates({name, _filename, _loaded_path}) when is_list(name),
    do: [List.to_atom(name)]

  defp candidates({name, _filename, _loaded_path}) when is_binary(name),
    do: [String.to_atom(name)]

  defp namespace?(module) when is_atom(module) do
    name = Atom.to_string(module)
    String.starts_with?(name, @namespace) and name != @namespace
  end

  # Same deterministic test-tree exclusion as Catalog.Discover and
  # Provider.Discover: the beam's recorded source path must not live under a
  # `test` tree segment.
  defp test_source?(module) do
    case :code.which(module) do
      path when is_list(path) ->
        info =
          case :beam_lib.chunks(path, [:compile_info]) do
            {:ok, {_file, {compile_info, info}}} when compile_info == :compile_info -> info
            {:ok, {_file, [{compile_info, info}]}} when compile_info == :compile_info -> info
            _ -> []
          end

        info |> Keyword.get(:source, []) |> List.to_string() |> test_tree_path?()

      _ ->
        false
    end
  end

  defp test_tree_path?(source) do
    segments = Path.split(source)

    case Enum.find_index(segments, &(&1 == "test")) do
      nil ->
        false

      index ->
        remainder = Enum.drop(segments, index + 1)
        remainder != [] and List.last(remainder) == Path.basename(source)
    end
  end

  defp conforming?(module) do
    case Code.ensure_loaded(module) do
      {:module, loaded} ->
        behaviours = loaded.module_info(:attributes) |> Keyword.get(:behaviour, [])

        if Workstation.Core.Contracts.Contract in behaviours do
          Enum.each(@callbacks, fn {callback, arity} ->
            function_exported?(loaded, callback, arity) ||
              raise ArgumentError,
                    "#{inspect(loaded)} declares the effect-contract behaviour but does not define #{callback}/#{arity}"
          end)

          true
        else
          false
        end

      {:error, _reason} ->
        false
    end
  end
end
