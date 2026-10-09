defmodule Workstation.Core.Catalog.Discover do
  @moduledoc """
  Runtime package-spec discovery: the catalog is composed from whatever
  conforming provider modules the code path carries, never from a
  hand-written registration list.

  Provider contract (see `Workstation.Core.Catalog.Spec`): a module under
  the `Workstation.Packages.*` namespace that declares the
  behaviour and defines `spec/0`. Discovery is deterministic on three
  axes:

  * candidates come from `:code.all_available/0`, narrowed to the
    discovery namespace (package modules are compiled into the app either
    way; the namespace only keeps the loader from touching dependency
    beams) and sorted by module name — declaration order is not a thing;
  * `test/support` fixtures (and any module compiled from a test tree) are
    excluded deterministically by the beam's recorded source path, so test
    fixtures can never leak into the live catalog;
  * conformance is validated before use: the behaviour attribute, the
    `spec/0` export, spec shape (`Spec.validate!/2`) and duplicate package
    ids across distinct providers — each rejection names the offending
    module.

  The candidate/test-tree/conformance pipeline is the shared
  `Workstation.Core.Contracts.Discovery` helper — this module supplies
  the package-spec parameterization plus the spec-shape and duplicate-id
  validation that only the catalog envelope owns.
  """

  alias Workstation.Core.Catalog.Spec

  @doc """
  The discovered provider modules, sorted by module name — the same order
  their ids sort in, which is the graph's tie-break, not a registration
  order.
  """
  @spec providers() :: [module()]
  def providers do
    Workstation.Core.Contracts.Discovery.modules(%{
      namespace: "Elixir.Workstation.Packages.",
      behaviour: Spec,
      callbacks: [spec: 0],
      label: "package-spec"
    })
  end

  @doc """
  The discovered packages: every provider's validated spec, in the same
  deterministic (module-name) order. Duplicate ids across distinct
  providers are rejected with both module names.
  """
  @spec specs() :: [map()]
  def specs do
    providers()
    |> Enum.map(fn module -> {module, module.spec()} end)
    |> tap(&validate_specs/1)
    |> Enum.map(fn {_module, spec} -> spec end)
  end

  # Shape + duplicate-id validation for a module->spec list; shared by
  # discovery and by direct tests of the rejection contract.
  @doc false
  @spec validate_specs([{module(), map()}]) :: :ok
  def validate_specs(pairs) do
    Enum.each(pairs, fn {module, spec} -> Spec.validate!(spec, module) end)

    declarers =
      Enum.reduce(pairs, %{}, fn {module, spec}, seen ->
        Map.update(seen, Map.fetch!(spec, :id), [module], &[module | &1])
      end)

    Enum.each(declarers, fn
      {_id, [_single]} -> :ok
      {id, modules} -> raise ArgumentError, "duplicate package id #{id} declared by #{inspect(Enum.reverse(modules))}"
    end)

    :ok
  end

end
