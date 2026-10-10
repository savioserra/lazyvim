defmodule Workstation.Core.Catalog.Discover do
  @moduledoc """
  Runtime package-spec discovery: the catalog is composed from whatever
  manifests the package tree carries, never from a hand-written
  registration list. Two arms, one catalog:

  * the compiled arm — a `manifest.ex` in the package dir defining a
    `Workstation.Core.Catalog.Spec` provider (`spec/0`); candidates are
    exactly the modules the loaded package tree declared
    (`Workstation.Core.Packages.Loader.ensure/0` walks it once per node),
    a package is added by adding its directory, and a module outside the
    tree is structurally invisible to discovery;
  * the data arm — a `manifest.json` in the package dir, read and
    denormalized by `Workstation.Core.Packages.Reader`.

  Both arms share the spec-shape validation (`Spec.validate!/2`) and the
  duplicate-id rejection — each failure names the offending module or
  manifest path — and the merged catalog is id-ordered: the graph's
  tie-break, not a registration order.

  The candidate/test-tree/conformance pipeline is the shared
  `Workstation.Core.Contracts.Discovery` helper — this module supplies
  the package-spec parameterization plus the spec-shape and duplicate-id
  validation that only the catalog envelope owns.
  """

  alias Workstation.Core.Catalog.Spec
  alias Workstation.Core.Packages.Reader

  @doc """
  The discovered provider modules, sorted by module name — the same order
  their ids sort in, which is the graph's tie-break, not a registration
  order.
  """
  @spec providers() :: [module()]
  def providers do
    Workstation.Core.Contracts.Discovery.modules(%{
      behaviour: Spec,
      callbacks: [spec: 0],
      label: "package-spec"
    })
  end

  @doc """
  The discovered packages: the compiled providers' validated specs merged
  with the data manifests (`Workstation.Core.Packages.Reader`), in id
  order — the graph's tie-break, not a registration order. Duplicate ids
  across distinct declarers (modules or manifest paths) are rejected
  naming both.
  """
  @spec specs() :: [map()]
  def specs do
    (Enum.map(providers(), fn module -> {module, module.spec()} end) ++ Reader.specs())
    |> tap(&validate_specs/1)
    |> Enum.sort_by(fn {_declarer, spec} -> Map.fetch!(spec, :id) end)
    |> Enum.map(&elem(&1, 1))
  end

  # Shape + duplicate-id validation for a declarer->spec list (compiled
  # provider modules and data-manifest paths alike); shared by discovery
  # and by direct tests of the rejection contract.
  @doc false
  @spec validate_specs([{module() | String.t(), map()}]) :: :ok
  def validate_specs(pairs) do
    Enum.each(pairs, fn {declarer, spec} -> Spec.validate!(spec, declarer) end)

    declarers =
      Enum.reduce(pairs, %{}, fn {declarer, spec}, seen ->
        Map.update(seen, Map.fetch!(spec, :id), [declarer], &[declarer | &1])
      end)

    Enum.each(declarers, fn
      {_id, [_single]} -> :ok
      {id, declarers} -> raise ArgumentError, "duplicate package id #{id} declared by #{inspect(Enum.reverse(declarers))}"
    end)

    :ok
  end

end
