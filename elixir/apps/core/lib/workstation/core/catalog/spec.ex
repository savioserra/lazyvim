defmodule Workstation.Core.Catalog.Spec do
  @moduledoc """
  The package-spec provider behaviour: one conforming module per workstation
  package, discovered at runtime instead of registered by hand.

  The contributor contract is intentionally narrow — a package declares ONLY
  its own identity and edges and never needs to know that other packages
  exist:

  * the module lives under `Workstation.Core.Catalog.Packages.*` (the
    discovery namespace) and declares `@behaviour
    #{inspect(__MODULE__)}`;
  * `spec/0` returns the package's specification map: `:id` (unique
    string), `:requires` (necessity + ordering edges), the optional
    `:after` (ordering-only edges), `:supported_hosts`, `:foundation` and
    `:contributes` — everything else is discovery-validated here and graph
    or recipe-validated downstream;
  * ordering between packages comes exclusively from `requires`/`after`
    edges. Any `:order`/`:position`/`:priority` field on the package spec
    is rejected at discovery time: integer ordering knobs do not scale to
    independent contributors (two packages cannot both own "position 3"),
    and graph ties resolve by id sort instead.

  Adding a package is dropping in a conforming module — zero engine edits.
  `Workstation.Core.Catalog.Discover` finds the providers via
  `:code.all_available/0` and this behaviour, and `CatalogNativeTest`
  remains the drift anchor for the composed bytes.
  """

  @callback spec() :: map()

  # The banned design: integer ordering fields on the package spec. The ban
  # is on PRESENCE — any ordering knob at package level reintroduces the
  # hand-coordinated registry this discovery layer replaces.
  @banned_ordering_keys [:order, :position, :priority]

  @doc """
  Validate one provider's spec map (shape, identity, edges, the banned
  ordering keys) with actionable errors. `context` names the declaring
  module so discovery failures point at the file to fix.
  """
  @spec validate!(map(), module()) :: :ok
  def validate!(spec, context) when is_atom(context) do
    is_map(spec) || raise_arg(context, "spec() must return a map")
    id = string_field(spec, :id, context, "id")
    string_field(spec, :foundation, context, "foundation")

    Enum.each(@banned_ordering_keys, fn key ->
      Map.has_key?(spec, key) &&
        raise_arg(
          context,
          "spec declares #{inspect(key)} — integer ordering fields are banned on package " <>
            "specs; order packages with requires/after edges instead (ties resolve by id sort)"
        )
    end)

    validate_edge_list(Map.get(spec, :requires) || [], "#{id}.requires", context)
    validate_edge_list(Map.get(spec, :after) || [], "#{id}.after", context)

    case Map.get(spec, :supported_hosts) do
      nil ->
        :ok

      hosts when is_map(hosts) ->
        Enum.each(hosts, fn
          {host, supported} when is_binary(host) and is_boolean(supported) -> :ok
          _ -> raise_arg(context, "#{id}.supported_hosts must map host names to booleans")
        end)

      _ ->
        raise_arg(context, "#{id}.supported_hosts must be an object or nil")
    end

    contributes = Map.get(spec, :contributes) || []
    is_list(contributes) || raise_arg(context, "#{id}.contributes must be a list")

    :ok
  end

  defp string_field(spec, key, context, label) do
    value = Map.get(spec, key)
    is_binary(value) and value != "" || raise_arg(context, "#{label} must be a non-empty string")
    value
  end

  defp validate_edge_list(edges, _label, context) when not is_list(edges),
    do: raise_arg(context, "dependency edges must be a list of package id strings")

  defp validate_edge_list(edges, label, context) do
    Enum.each(edges, fn edge ->
      is_binary(edge) and edge != "" ||
        raise_arg(context, "#{label} must contain only non-empty strings, got #{inspect(edge)}")
    end)
  end

  defp raise_arg(context, message),
    do: raise(ArgumentError, "#{inspect(context)} (package spec): #{message}")
end
