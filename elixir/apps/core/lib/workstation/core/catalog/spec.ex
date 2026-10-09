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

  # The package-context surface (docs: package-context-api). Exports are
  # what a package PUBLISHES under its own capability namespace; context
  # requirements are what it CONSUMES from its declared dependencies. The
  # capability IS the namespace (same law as the store's
  # namespace-as-layout): an export key must be the package's own id, a
  # context_require key must be a declared dependency. Exports are PURE
  # DATA — wire-shaped, string-keyed, no functions, refs or atom-keyed
  # maps — validated fail-closed here so neither the native path nor a
  # recorded envelope can smuggle computation or world reads into compose.
  @export_fields [:key, :schema, :value]
  @context_require_fields [:key, :schema]

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

    validate_exports_native(Map.get(spec, :exports), id, context)

    requires = Map.get(spec, :requires) || []
    context_requires = annotate_membership(Map.get(spec, :context_requires), requires)
    validate_context_requires_native(context_requires, id, context)

    :ok
  end

  # --- the package-context surface ---

  @doc """
  Validate one package's export declarations: each entry carries exactly
  key/schema/value, the key IS the package's own capability namespace (its
  id — one export per capability), the schema is a positive integer, and the
  value is pure string-keyed data. The purity rule is the compose-stage
  contract: exports are a pure function of (manifest, dependency context),
  so nothing that could read the world (functions, refs, pids) and nothing
  that could not survive the recorded wire (atom-keyed maps) may be
  declared. Raises `ArgumentError` with the package id named.
  """
  @spec validate_exports([map()], String.t()) :: :ok
  def validate_exports(exports, id) when is_list(exports) do
    Enum.each(exports, fn export ->
      is_map(export) || arg("#{id}.exports entries must be objects")
      unknown = Map.keys(export) -- @export_fields
      unknown == [] || arg("#{id}.exports has unknown fields: #{inspect(unknown)}")

      key = Map.get(export, :key)
      is_binary(key) and key != "" || arg("#{id}.exports requires a non-empty string key")
      key == id ||
        arg(
          "#{id}.exports key #{inspect(key)} must be the package's own capability namespace " <>
            "(one export per capability; the capability IS the id)"
        )

      schema = Map.get(export, :schema)
      is_integer(schema) and schema > 0 || arg("#{id}.exports #{key} schema must be a positive integer")
      pure_data?(Map.get(export, :value)) ||
        arg(
          "#{id}.exports #{key} value must be pure string-keyed data " <>
            "(objects/arrays/strings/numbers/booleans — no functions, refs, or atom-keyed maps)"
        )
    end)

    :ok
  end

  def validate_exports(other, id), do: arg("#{id}.exports must be a list, got: #{inspect(other)}")

  @doc """
  Validate one package's context requirements: each entry carries exactly
  key/schema, the key names a DECLARED dependency (least knowledge — a
  package's view contains only what its manifest says it needs), and the
  schema is a version range: a positive integer (exact) or a string of
  space-separated constraints (">=1 <2", "1", "==1"). Raises
  `ArgumentError` with the package id named.
  """
  @spec validate_context_requires([map()], String.t()) :: :ok
  def validate_context_requires(requires, id) when is_list(requires) do
    Enum.each(requires, fn req ->
      is_map(req) || arg("#{id}.context_requires entries must be objects")

      # :in_requires is the CALLER's membership annotation (the declared
      # requires list is the caller's knowledge), not a declared field.
      unknown = Map.keys(req) -- (@context_require_fields ++ [:in_requires])
      unknown == [] || arg("#{id}.context_requires has unknown fields: #{inspect(unknown)}")

      key = Map.get(req, :key)
      is_binary(key) and key != "" || arg("#{id}.context_requires requires a non-empty string key")
      Map.get(req, :in_requires) == true ||
        arg(
          "#{id}.context_requires key #{inspect(key)} must name a capability provided by one of " <>
            "the package's manifest dependencies (requires)"
        )

      valid_range?(Map.get(req, :schema)) ||
        arg("#{id}.context_requires #{key} schema must be a positive integer or a constraint string (\">=1 <2\")")
    end)

    :ok
  end

  def validate_context_requires(other, id),
    do: arg("#{id}.context_requires must be a list, got: #{inspect(other)}")

  @doc """
  Whether one exported schema VERSION is covered by a consumer's declared
  RANGE (a positive integer pins exactly; a string holds space-separated
  `>=`/`<=`/`==`/`>`/`<` constraints). Malformed ranges fail closed.
  """
  @spec schema_covered?(pos_integer(), pos_integer() | String.t()) :: boolean()
  def schema_covered?(version, range) when is_integer(version) and version > 0 do
    constraints =
      cond do
        is_integer(range) ->
          range > 0 || arg("schema range must be a positive integer or constraint string")
          [">=#{range}", "<=#{range}"]

        is_binary(range) ->
          parts = String.split(range, " ", trim: true)
          parts != [] || arg("schema range must not be empty")
          parts

        true ->
          arg("schema range must be a positive integer or constraint string, got: #{inspect(range)}")
      end

    Enum.all?(constraints, fn constraint ->
      case Regex.run(~r/\A(>=|<=|==|>|<)?(\d+)\z/, constraint) do
        [_all, op, digits] -> compare_version(version, normalize_op(op), String.to_integer(digits))
        _ -> arg("invalid schema range constraint #{inspect(constraint)}")
      end
    end)
  end

  def schema_covered?(_version, range),
    do: arg("schema range must be a positive integer or constraint string, got: #{inspect(range)}")

  defp validate_exports_native(nil, _id, _context), do: :ok

  defp validate_exports_native(exports, id, context) when is_list(exports) do
    validate_exports(exports, id)
  rescue
    e in [ArgumentError] -> raise_arg(context, Exception.message(e))
  end

  defp validate_exports_native(other, id, context),
    do: raise_arg(context, "#{id}.exports must be a list, got: #{inspect(other)}")

  # Membership annotation: a context_require must name a DECLARED
  # dependency. The validator stays pure over the annotated entries so the
  # recorded-envelope path can annotate from its own parsed requires.
  defp annotate_membership(requires, declared) when is_list(requires) do
    Enum.map(requires, fn
      req when is_map(req) -> Map.put(req, :in_requires, Enum.member?(declared, Map.get(req, :key)))
      other -> other
    end)
  end

  defp annotate_membership(other, _declared), do: other

  defp validate_context_requires_native(nil, _id, _context), do: :ok

  defp validate_context_requires_native(requires, id, context) when is_list(requires) do
    validate_context_requires(requires, id)
  rescue
    e in [ArgumentError] -> raise_arg(context, Exception.message(e))
  end

  defp validate_context_requires_native(other, id, context),
    do: raise_arg(context, "#{id}.context_requires must be a list, got: #{inspect(other)}")

  # An absent operator is an exact pin: "1" means "==1".
  defp normalize_op(op) when op in [nil, ""], do: "=="
  defp normalize_op(op), do: op

  defp compare_version(v, "==", n), do: v == n
  defp compare_version(v, ">=", n), do: v >= n
  defp compare_version(v, "<=", n), do: v <= n
  defp compare_version(v, ">", n), do: v > n
  defp compare_version(v, "<", n), do: v < n

  defp valid_range?(n) when is_integer(n) and n > 0, do: true

  defp valid_range?(range) when is_binary(range) do
    parts = String.split(range, " ", trim: true)
    parts != [] and Enum.all?(parts, &Regex.match?(~r/\A(>=|<=|==|>|<)?\d+\z/, &1))
  end

  defp valid_range?(_), do: false

  # The purity rule: export values are wire data and nothing else. A value
  # that is not string-keyed data cannot be recorded, cannot replay, and
  # could hide a computation — all three fail here, at the declaration.
  defp pure_data?(value) when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
    do: true

  defp pure_data?(value) when is_list(value), do: Enum.all?(value, &pure_data?/1)

  defp pure_data?(value) when is_map(value) do
    Enum.all?(value, fn
      {key, inner} when is_binary(key) -> pure_data?(inner)
      _other -> false
    end)
  end

  defp pure_data?(_value), do: false

  defp arg(message), do: raise(ArgumentError, message)

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
