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

  Data manifests complement the compiled `manifest.ex` arm where a package
  still carries one: `Workstation.Core.Catalog.Discover`
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

  # The `$embed_assets` render descriptor's vocabulary (template + embed are
  # package-relative asset references; marker is the substitution token the
  # template carries exactly once).
  @embed_fields ~w(embed marker template)

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
  defp contribution!(path, package_id, entry) when is_map(entry) do
    unknown = Map.keys(entry) -- @contribution_fields
    unknown == [] || raise(ArgumentError, "#{package_id} contribution has unknown fields: #{inspect(unknown)}")

    provider = manifest_string!(package_id, entry, "provider")
    spec = Map.get(entry, "spec")
    is_map(spec) || raise(ArgumentError, "#{package_id} contribution spec must be an object")
    reject_ordering_keys!(path, package_id, spec)
    spec = expand_rendered_values(package_id, spec)

    ctx = %{
      package_id: package_id,
      assets: nil,
      live_home: nil,
      canonical_home: Workstation.Core.Catalog.canonical_home(),
      declared: true
    }

    dispatch = dispatch()

    case Map.fetch(dispatch.providers, provider) do
      {:ok, module} ->
        %{provider: provider, spec: module.denormalize_spec(spec)}

      :error ->
        case Map.fetch(dispatch.contracts, provider) do
          {:ok, module} -> %{provider: provider, spec: module.from_recorded(spec, ctx)}
          :error -> raise(ArgumentError, "#{package_id} contribution names unknown provider #{inspect(provider)}")
        end
    end
  end

  @dispatch_key {__MODULE__, :dispatch}

  # The discovered dispatch maps, resolved ONCE PER NODE (the loader's law):
  # every declared contribution dispatches through them, so the discovery
  # scans run one per node — not one per contribution. Discovery output is
  # deterministic on a loaded tree, which is exactly what makes the cache
  # honest.
  defp dispatch do
    case :persistent_term.get(@dispatch_key, :missing) do
      :missing ->
        maps = %{providers: Provider.Discover.by_id(), contracts: Contract.Discover.by_id()}
        :persistent_term.put(@dispatch_key, maps)
        maps

      maps ->
        maps
    end
  end

  defp contribution!(_path, package_id, other),
    do: raise(ArgumentError, "#{package_id} contribution must be an object, got: #{inspect(other)}")

  # The banned-design walk — the package-level rule extended to every
  # declared contribution, at every nesting depth: an ordering knob anywhere
  # in a data manifest is a rejected field, because composition order is
  # collection order (the stable walk: dependencies first, ties by id sort)
  # and a declared number reintroduces the hand-coordinated registry.
  defp reject_ordering_keys!(path, package_id, value) when is_map(value) do
    Enum.each(value, fn
      {key, _inner} when key in @banned_fields ->
        raise ArgumentError,
              "#{path} declares \"#{key}\" inside #{package_id}'s contribution — integer " <>
                "ordering fields are banned on package declarations; composition order is " <>
                "collection order (the stable walk: dependencies first, ties by id sort)"

      {_key, inner} ->
        reject_ordering_keys!(path, package_id, inner)
    end)
  end

  defp reject_ordering_keys!(path, package_id, value) when is_list(value) do
    Enum.each(value, &reject_ordering_keys!(path, package_id, &1))
  end

  defp reject_ordering_keys!(_path, _package_id, _leaf), do: :ok

  # The engine-rendered sentinel vocabulary — the one thing a data manifest
  # cannot carry as bytes. The set is closed: a rendered value joins here or
  # it does not exist.
  #
  # * `%{"$theme_data" => true}` expands to the theme platform engine's
  #   canonical chezmoidata envelope, rendered from the committed token set
  #   (the same engine call the retired compiled declaration made).
  # * `%{"$embed_assets" => descriptor}` expands to the composed modify
  #   program the retired compiled declaration built: pure-filesystem reads
  #   of the two declared package assets — the template and the embedded
  #   body — substituted at the declared marker (first occurrence only, the
  #   single-marker semantics the template itself carries), fail-closed on
  #   any missing/empty asset, a body that is not a JSON object, an absent
  #   marker, or a substitution that leaves a marker behind.
  defp expand_rendered_values(package_id, spec) do
    Map.new(spec, fn
      {key, %{"$theme_data" => true}} ->
        {key, Workstation.Core.Theme.Tokens.data_envelope()}

      {key, %{"$embed_assets" => descriptor}} ->
        {key, embed_assets!(package_id, descriptor)}

      {key, value} ->
        {key, value}
    end)
  end

  # The declared-asset embed: template + body reads through the catalog's
  # one auditable asset seam (package-relative, pure filesystem), then the
  # exact compiled-arm semantics — the pins must decode as a JSON object and
  # the template must carry the marker exactly once in effect. Returns the
  # composed program bytes; every failure names the package and the field.
  defp embed_assets!(package_id, descriptor) when is_map(descriptor) do
    unknown = Map.keys(descriptor) -- @embed_fields
    unknown == [] || raise(ArgumentError, "#{package_id} render descriptor has unknown fields: #{inspect(unknown)}")

    template_ref = field_string!(package_id, descriptor, "template")
    embed_ref = field_string!(package_id, descriptor, "embed")
    marker = field_string!(package_id, descriptor, "marker")

    template = Workstation.Core.Catalog.package_asset!(package_id, template_ref)
    body = Workstation.Core.Catalog.package_asset!(package_id, embed_ref)

    case Workstation.Core.EngineState.decode_json(body) do
      {:ok, decoded} when is_map(decoded) -> :ok
      _ -> raise ArgumentError, "#{package_id}: #{embed_ref} asset is not a JSON object"
    end

    String.contains?(template, marker) ||
      raise ArgumentError, "#{package_id}: #{template_ref} asset carries no #{marker} marker"

    replaced = :binary.replace(template, marker, body)

    String.contains?(replaced, marker) &&
      raise ArgumentError, "#{package_id}: #{template_ref} asset substitution failed"

    replaced
  end

  defp embed_assets!(package_id, other),
    do: raise(ArgumentError, "#{package_id} render descriptor must be an object, got: #{inspect(other)}")

  defp field_string!(package_id, descriptor, field) do
    value = Map.get(descriptor, field)
    is_binary(value) and value != "" || raise(ArgumentError, "#{package_id} render descriptor #{field} must be a non-empty string")
    value
  end

  defp manifest_string!(source, map, field) do
    value = Map.get(map, field)
    is_binary(value) and value != "" || raise(ArgumentError, "#{source}: #{field} must be a non-empty string")
    value
  end
end
