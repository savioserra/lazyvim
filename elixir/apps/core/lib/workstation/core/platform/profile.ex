defmodule Workstation.Core.Platform.Profile do
  @moduledoc """
  Layer: platform. The platform law: this module names no consumer —
  editor capabilities derive from it, declaring their field vocabulary as a
  shape and owning their serialization; the platform owns the envelope, the
  ordering and the validation law (docs/architecture.md, "Module hierarchy
  & moduledoc conventions").
  The profile platform — the envelope and ordering law every editor
  capability's profile compositor rides.

  A profile recipe is the envelope `%{order: pos_integer, entry: map}`: the
  explicit order key fixes domain order, graph collection order breaks ties.
  An editor capability declares its own field vocabulary as a `shape` —

      %{
        string_fields: [:id, :plugin_module],  # :id required, others optional
        list_fields: [:requires, ...],         # non-empty string lists
        case_fields: %{language_cases: [...]}  # case-record lists + project_files
      }

  — and owns its serialization (the deployed file's own format). This
  platform owns everything else: shape-driven entry validation, the
  declared/recorded normalization twins (atom-keyed declarations vs the
  recorded envelope's string keys), composition ordering (explicit order
  key, collection-order tie-break), and duplicate-id rejection. A new
  editor implements the same compositor shape on its own vocabulary without
  the engine learning its name.
  """

  @type shape :: %{
          required(:string_fields) => [atom()],
          required(:list_fields) => [atom()],
          required(:case_fields) => %{optional(atom()) => [atom()]}
        }
  @type intent :: %{required(:owner) => String.t(), required(:spec) => map()}

  # The canonical profile-intent envelope: the field vocabulary every
  # language intent declares, wherever the intent is contributed from. The
  # vocabulary is mechanism (shape, normalization, validation); what the
  # fields MEAN for a given editor is the owning capability's semantics.
  @intent_shape %{
    string_fields: [:id, :plugin_module],
    list_fields: [:requires, :lazyvim_extras, :mason_packages],
    case_fields: %{language_cases: [:language, :filename, :contents, :client], formatter_cases: [:language, :filename, :contents, :expected]}
  }

  @doc """
  The canonical profile-intent envelope — the shape language intents
  declare, wherever they are contributed from. Editors own what the fields
  mean for them; the envelope, its normalization and its validation are
  the platform's.
  """
  @spec intent_shape() :: shape()
  def intent_shape, do: @intent_shape

  @doc """
  One profile-intent contribution: normalize the declared raw intent to
  the canonical envelope, validate it, and wrap it as
  `%{provider: provider_id, spec: %{order:, entry:}}`. The caller names
  the profile capability's provider id as data (the same way recipe
  constructors name "chezmoi"), so the platform never names one.
  """
  @spec contribution(String.t(), pos_integer(), map()) :: %{provider: String.t(), spec: map()}
  def contribution(provider_id, order, raw) when is_binary(provider_id) do
    spec = %{order: order, entry: declared_entry(raw, @intent_shape)}
    :ok = validate_intent_spec(spec, @intent_shape, "profile intent")
    %{provider: provider_id, spec: spec}
  end

  @doc """
  Envelope validation for one profile-intent recipe: a positive integer
  order, an entry table, and the entry valid under the canonical shape.
  Label prefixes every rejection.
  """
  @spec validate_intent_spec(map(), shape(), String.t()) :: :ok
  def validate_intent_spec(spec, shape, label) do
    order = spec[:order]
    unless is_integer(order) and order > 0,
      do: raise_arg(label <> " recipe requires a positive integer order")
    unless is_map(spec[:entry]), do: raise_arg(label <> " recipe requires an entry table")
    validate_entry(spec[:entry], shape, label <> " entry " <> (spec[:entry][:id] |> to_string()))
    :ok
  end

  @doc """
  The composition ordering law: entries sorted by the recipe's explicit
  order key with collection order as tie-break. Owners are NOT threaded
  through here on purpose — attribution stays the caller's fact about
  contribution, in collection order.
  """
  @spec order_intents([intent()]) :: [map()]
  def order_intents(intents) when is_list(intents) do
    intents
    |> Enum.with_index(1)
    |> Enum.sort_by(fn {intent, sequence} -> {intent.spec[:order], sequence} end)
    |> Enum.map(fn {intent, _sequence} -> intent.spec[:entry] end)
  end

  @doc """
  Validate a composed profile: a list, every entry valid under `shape`, no
  duplicate entry ids. Returns the profile unchanged; raises
  `ArgumentError` otherwise.
  """
  @spec validate_profile(term(), shape(), String.t()) :: [map()]
  def validate_profile(profile, shape, label) when is_list(profile) do
    {_, _} =
      Enum.reduce(profile, {1, MapSet.new()}, fn entry, {index, ids} ->
        validate_entry(entry, shape, label <> "[" <> Integer.to_string(index) <> "]")

        id = entry[:id]
        MapSet.member?(ids, id) && raise_arg("duplicate " <> label <> " contribution: " <> id)
        {index + 1, MapSet.put(ids, id)}
      end)

    profile
  end

  def validate_profile(_profile, _shape, label), do: raise_arg(label <> " must be a list")

  @doc """
  Shape-driven entry validation: the identity field (`:id`) is a required
  non-empty string, the remaining string fields are non-empty when present,
  list fields are non-empty string lists, case fields are case-record lists
  (every declared base field a non-empty string, optional string-keyed
  `project_files`). Returns the entry unchanged.
  """
  @spec validate_entry(term(), shape(), String.t()) :: map()
  def validate_entry(entry, shape, label) do
    unless is_map(entry), do: raise_arg(label <> " must be a table")

    [id_field | optional_strings] = shape.string_fields

    nonempty_string?(entry[id_field]) ||
      raise_arg(label <> "." <> Atom.to_string(id_field) <> " must be a non-empty string")

    Enum.each(optional_strings, fn field ->
      if entry[field] != nil,
        do: nonempty_string?(entry[field]) || raise_arg(label <> ".#{field} must be a non-empty string")
    end)

    Enum.each(shape.list_fields, fn field ->
      if entry[field] != nil, do: validate_string_list(entry[field], label <> ".#{field}")
    end)

    Enum.each(shape.case_fields, fn {field, case_shape} ->
      if entry[field] != nil, do: validate_cases(entry[field], case_shape, label <> ".#{field}")
    end)

    entry
  end

  @doc """
  Normalize one declared intent entry (atom-keyed, contribute/2 input) to
  the shape's full record: every declared field present (nil when the
  language omits it), case records carrying exactly their base fields plus
  optional string-keyed project_files — so native entries compare equal to
  the recorded envelope's projection.
  """
  @spec declared_entry(map(), shape()) :: map()
  def declared_entry(raw, shape) when is_map(raw) do
    plain = shape.string_fields ++ shape.list_fields

    plain_record = Map.new(plain, fn field -> {field, Map.get(raw, field)} end)

    case_record =
      Map.new(shape.case_fields, fn {field, case_shape} ->
        {field, declared_cases(Map.get(raw, field), case_shape)}
      end)

    Map.merge(plain_record, case_record)
  end

  def declared_entry(_raw, _shape), do: raise_arg("profile intent must be a table")

  @doc """
  Denormalize one recorded-envelope recipe (string-keyed golden bytes) back
  to the declared atom shape: order must be a positive integer, the entry a
  table; list values fail closed on non-strings, unknown fields are
  tolerated (the validator checks known fields without an allowlist).
  Raises `ArgumentError` on invalid shape; `label` prefixes the messages.
  """
  @spec recorded_spec(map(), shape(), String.t()) :: map()
  def recorded_spec(spec, shape, label) when is_map(spec) do
    order = Map.get(spec, "order")

    unless is_integer(order) and order > 0,
      do: raise_arg(label <> " order must be a positive integer")

    %{order: order, entry: recorded_entry(Map.get(spec, "entry"), shape, label)}
  end

  def recorded_spec(_spec, _shape, label), do: raise_arg(label <> " recipe must be a table")

  # --- private: shape-driven checks ---

  defp validate_string_list(values, label) when is_list(values) do
    Enum.with_index(values, 1)
    |> Enum.each(fn {value, index} ->
      nonempty_string?(value) ||
        raise_arg(label <> "[" <> Integer.to_string(index) <> "] must be a non-empty string")
    end)

    :ok
  end

  defp validate_string_list(_values, label), do: raise_arg(label <> " must be a list")

  defp validate_cases(cases, fields, label) when is_list(cases) do
    Enum.with_index(cases, 1)
    |> Enum.each(fn {case, index} ->
      unless is_map(case), do: raise_arg(label <> "[" <> Integer.to_string(index) <> "] must be a table")

      Enum.each(fields, fn field ->
        nonempty_string?(case[field]) ||
          raise_arg(label <> "[" <> Integer.to_string(index) <> "].#{field} must be a non-empty string")
      end)
    end)

    :ok
  end

  defp validate_cases(_cases, _fields, label), do: raise_arg(label <> " must be a list")

  defp nonempty_string?(value), do: is_binary(value) and value != ""

  defp raise_arg(message), do: raise(ArgumentError, message)

  # --- private: declared-entry case normalization ---

  defp declared_cases(nil, _fields), do: nil

  defp declared_cases(cases, fields) when is_list(cases) do
    Enum.map(cases, fn case ->
      base = Map.new(fields, fn field -> {field, Map.fetch!(case, field)} end)

      case Map.fetch(case, :project_files) do
        {:ok, files} -> Map.put(base, :project_files, files)
        :error -> base
      end
    end)
  end

  # --- private: recorded-envelope copies (string-keyed, fail-closed) ---

  defp recorded_entry(raw, shape, label) do
    unless is_map(raw), do: raise_arg(label <> " entry must be a table")

    string_record = Map.new(shape.string_fields, fn field -> {field, raw[Atom.to_string(field)]} end)

    list_record =
      Map.new(shape.list_fields, fn field ->
        {field, copy_string_list(raw[Atom.to_string(field)], label)}
      end)

    case_record =
      Map.new(shape.case_fields, fn {field, case_shape} ->
        {field, copy_cases(raw[Atom.to_string(field)], case_shape, label)}
      end)

    Map.merge(string_record, Map.merge(list_record, case_record))
  end

  defp copy_cases(nil, _fields, _label), do: nil

  defp copy_cases(cases, fields, label) when is_list(cases) do
    Enum.map(cases, fn case ->
      unless is_map(case), do: raise_arg(label <> " case must be a table")

      base = Map.new(fields, fn field -> {field, require_nonempty(case, field, label)} end)

      if Map.has_key?(case, "project_files") do
        files = case["project_files"]
        unless is_map(files), do: raise_arg(label <> " project_files must be a table")
        Map.put(base, :project_files, files)
      else
        base
      end
    end)
  end

  defp copy_cases(_cases, _fields, label), do: raise_arg(label <> " cases must be a list")

  defp copy_string_list(nil, _label), do: nil

  defp copy_string_list(values, label) when is_list(values) do
    Enum.each(values, &(nonempty_string?(&1) || raise_arg(label <> " list values must be non-empty strings")))
    values
  end

  defp copy_string_list(_values, label), do: raise_arg(label <> " list must be a list")

  defp require_nonempty(map, field, label) do
    value = Map.get(map, Atom.to_string(field))
    nonempty_string?(value) || raise_arg(label <> " case #{field} must be a non-empty string")
    value
  end
end
