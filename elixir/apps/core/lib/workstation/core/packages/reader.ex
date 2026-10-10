defmodule Workstation.Core.Packages.Reader do
  @moduledoc """
  Layer: kernel. The kernel law: the reader knows the package tree root,
  never a package — it walks the tree and reads the `manifest.json` data
  each package dir carries beside its payloads, fail-closed on every
  malformed, unknown or non-conforming shape. Manifests are pure data: the
  file declares the catalog-spec shape string-keyed under a `"schema"`
  version, shape validation is the shared `Workstation.Core.Catalog.Spec`,
  and every contribution denormalizes through the discovered
  provider/contract owners — the reader names none of them. Adding a
  package is adding a directory.

  Data manifests complement the compiled `manifest.ex` arm while the
  manifest-to-data conversion runs: `Workstation.Core.Catalog.Discover`
  owns the merge and the cross-arm duplicate-id rejection.
  """

  alias Workstation.Core.Catalog.Spec
  alias Workstation.Core.Contracts.Contract
  alias Workstation.Core.Contracts.Provider
  alias Workstation.Core.Packages.Loader

  @manifest "manifest.json"
  @schema 1

  # The manifest's package-level vocabulary — the string-keyed JSON dialect
  # of the catalog spec shape (`Workstation.Core.Catalog.Spec`). Anything
  # else in the file is a rejected field: a data manifest may not declare
  # keys the native spec contract never had.
  @spec_fields ~w(id foundation requires after supported_hosts exports context_requires contributes)
  @export_fields ~w(key schema value)
  @context_require_fields ~w(key schema)
  @contribution_fields ~w(provider spec)

  # The banned design (the same rule the recorded envelopes enforce through
  # `Catalog.load`): integer ordering fields on the package spec.
  @banned_fields ~w(order position priority)

  @doc """
  The data manifests the package tree declares, as `{manifest path, spec}`
  pairs in sorted-path order — discovery's data-arm candidates. The walk
  covers the tree law's package dirs (`packages/<id>` and the domain layout
  `packages/<domain>/<id>`, symlink-aware by inode), never deeper payload
  files. Every spec is denormalized to the native atom-keyed shape and
  validated, so the catalog envelope cannot tell a data manifest from a
  compiled one.
  """
  @spec specs() :: [{String.t(), map()}]
  def specs do
    root = Loader.root()

    [Path.join(root, "*/#{@manifest}"), Path.join(root, "*/*/#{@manifest}")]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq_by(&File.stat!(&1).inode)
    |> Enum.sort()
    |> Enum.map(fn path -> {path, manifest_spec!(path)} end)
  end

  @doc """
  Validate and denormalize one decoded manifest against its path — the
  rejection contract the walk applies, public for direct tests of the
  failure modes (the `Workstation.Core.Catalog.Discover.validate_specs/1`
  pattern). Returns the native atom-keyed spec; raises `ArgumentError`
  naming the manifest (or package) on every invalid shape.
  """
  @spec spec!(String.t(), term()) :: map()
  def spec!(path, raw)

  def spec!(path, raw) when is_map(raw) do
    Enum.each(@banned_fields, fn field ->
      Map.has_key?(raw, field) &&
        raise ArgumentError,
              "#{path} declares \"#{field}\" — integer ordering fields are banned on package " <>
                "specs; order packages with requires/after edges instead (ties resolve by id sort)"
    end)

    unknown = Map.keys(raw) -- ["schema" | @spec_fields]
    unknown == [] || raise(ArgumentError, "#{path} has unknown manifest fields: #{inspect(unknown)}")
    raw["schema"] == @schema || raise(manifest_schema_error(path, raw["schema"]))

    id = manifest_string!(path, raw, "id")

    Path.basename(Path.dirname(path)) == id ||
      raise ArgumentError,
            "#{path} declares id #{inspect(id)} — a package directory is named for its id (the tree law)"

    contributes = raw["contributes"] || []
    is_list(contributes) || raise(ArgumentError, "#{path}: contributes must be a list")

    spec = %{
      id: id,
      foundation: manifest_string!(path, raw, "foundation"),
      requires: raw["requires"] || [],
      supported_hosts: raw["supported_hosts"],
      contributes: Enum.map(contributes, &contribution!(path, id, &1))
    }

    spec = declared_list(spec, raw, "after")
    spec = declared_entries(spec, raw, "exports", &export!(path, &1))
    spec = declared_entries(spec, raw, "context_requires", &context_require!(path, &1))
    Spec.validate!(spec, path)
    spec
  end

  def spec!(path, other),
    do: raise(ArgumentError, "#{path}: package manifest must be an object, got: #{inspect(other)}")

  # One manifest file: decode fail-closed (the kernel JSON reader never
  # raises; a malformed manifest is a discovery failure naming its path).
  defp manifest_spec!(path) do
    case Workstation.Core.JSON.decode(File.read!(path)) do
      {:ok, raw} -> spec!(path, raw)
      {:error, :malformed} -> raise(ArgumentError, "#{path}: package manifest is not valid JSON")
    end
  end

  defp manifest_schema_error(path, schema) do
    ArgumentError.exception(
      "#{path} manifest schema must be #{@schema}, got: #{inspect(schema)} — bump the reader " <>
        "with the schema, never a manifest past it"
    )
  end

  # Nil-drop convention (the recorded envelope's rule): an absent optional
  # list keeps the denormalized spec byte-shape equal to a native spec
  # without the key.
  defp declared_list(spec, raw, field) do
    case raw[field] do
      nil -> spec
      value -> Map.put(spec, String.to_atom(field), value)
    end
  end

  defp declared_entries(spec, raw, field, convert) do
    case raw[field] do
      nil -> spec
      entries -> Map.put(spec, String.to_atom(field), Enum.map(entries, convert))
    end
  end

  defp export!(path, entry) when is_map(entry) do
    unknown = Map.keys(entry) -- @export_fields
    unknown == [] || raise(ArgumentError, "#{path}: export has unknown fields: #{inspect(unknown)}")

    %{
      key: manifest_string!(path, entry, "key"),
      schema: Map.get(entry, "schema"),
      value: Map.get(entry, "value")
    }
  end

  defp export!(path, other),
    do: raise(ArgumentError, "#{path}: export must be an object, got: #{inspect(other)}")

  defp context_require!(path, entry) when is_map(entry) do
    unknown = Map.keys(entry) -- @context_require_fields
    unknown == [] || raise(ArgumentError, "#{path}: context_require has unknown fields: #{inspect(unknown)}")

    %{
      key: manifest_string!(path, entry, "key"),
      schema: Map.get(entry, "schema")
    }
  end

  defp context_require!(path, other),
    do: raise(ArgumentError, "#{path}: context_require must be an object, got: #{inspect(other)}")

  # One declared contribution: `{provider, spec}` data dispatched to the
  # discovered owner — the provider contracts' denormalization, or the
  # effect contracts' recorded reader under the DECLARED bracket (asset
  # references stay package-relative references; destinations stay
  # verbatim). Unknown fields fail at the owner; an unknown provider fails
  # here. This is the same dispatch `Catalog.load` applies to recorded
  # envelopes — a data manifest is just the declaration the engine reads
  # itself.
  defp contribution!(_path, package_id, entry) when is_map(entry) do
    unknown = Map.keys(entry) -- @contribution_fields
    unknown == [] || raise(ArgumentError, "#{package_id} contribution has unknown fields: #{inspect(unknown)}")

    provider = manifest_string!(package_id, entry, "provider")
    spec = Map.get(entry, "spec")
    is_map(spec) || raise(ArgumentError, "#{package_id} contribution spec must be an object")

    ctx = %{
      package_id: package_id,
      assets: nil,
      live_home: nil,
      canonical_home: Workstation.Core.Catalog.canonical_home(),
      declared: true
    }

    case Provider.Discover.lookup(provider) do
      {:ok, module} ->
        %{provider: provider, spec: module.denormalize_spec(spec)}

      :error ->
        case Contract.Discover.lookup(provider) do
          {:ok, module} -> %{provider: provider, spec: module.from_recorded(spec, ctx)}
          :error -> raise(ArgumentError, "#{package_id} contribution names unknown provider #{inspect(provider)}")
        end
    end
  end

  defp contribution!(_path, package_id, other),
    do: raise(ArgumentError, "#{package_id} contribution must be an object, got: #{inspect(other)}")

  defp manifest_string!(source, map, field) do
    value = Map.get(map, field)
    is_binary(value) and value != "" || raise(ArgumentError, "#{source}: #{field} must be a non-empty string")
    value
  end
end
