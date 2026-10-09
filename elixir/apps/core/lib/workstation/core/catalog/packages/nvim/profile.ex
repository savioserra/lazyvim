defmodule Workstation.Core.Catalog.Packages.Nvim.Profile do
  @moduledoc """
  The nvim capability's own profile compositor, owned by its package module:
  collects nvim-profile intents, fixes their order, and serializes the
  shared deployed profile file. Implements the generic
  `Workstation.Core.Source.Provider` contract, so the assembler discovers
  and dispatches it without naming this capability — dependency direction:
  consumer package -> provider contract, never the engine -> the consumer.

  It collects validated nvim-profile intents contributed through the generic
  envelope, fixes their explicit domain order, and emits ONE attributed
  chezmoi recipe for the shared deployed profile. Contributors keep fragment
  attribution; the compositor never fabricates per-fragment file ownership.

  `serialize/1` emits the deployed file as plain editor configuration Lua,
  quoted with Lua `%q` semantics (decimal escapes for control bytes, raw
  UTF-8, literal backslash-n for newlines after the recorder's one-line
  fold); the exact byte shape is pinned by the golden replay tests.
  """

  @behaviour Workstation.Core.Source.Provider

  @target ".config/nvim/lua/languages/profile.lua"

  @impl Workstation.Core.Source.Provider
  def id, do: "nvim-profile"

  @doc """
  One nvim-profile language intent (`packages/nvim/profile.lua` recipe) as
  declared by the nvim package module. The raw intent map is normalized to
  the envelope's denormalized shape here — every declared entry field
  present (nil when the language omits it), case records carrying exactly
  their base fields plus optional string-keyed project_files — so native
  intents compare equal to the recorded envelope and validate through the
  compositor's own entry validator.
  """
  @spec contribute(pos_integer(), map()) :: %{provider: String.t(), spec: map()}
  def contribute(order, raw) do
    spec = %{order: order, entry: denormalize_entry(raw)}
    :ok = validate_spec(spec)
    %{provider: id(), spec: spec}
  end

  @impl Workstation.Core.Source.Provider
  @doc """
  Denormalize one recorded-envelope spec (string-keyed golden bytes) back to
  the declared atom shape: known entry fields to atom keys, project_files
  keys staying data (file names, never structure). Unknown fields are
  tolerated exactly like the Lua validator, which checks known fields
  without an allowlist.
  """
  def denormalize_spec(spec) do
    order = Map.get(spec, "order")

    unless is_integer(order) and order > 0,
      do: raise_arg("nvim-profile order must be a positive integer")

    %{order: order, entry: denormalize_recorded_entry(Map.get(spec, "entry"))}
  end

  @spec validate_entry(term(), String.t()) :: map()
  def validate_entry(entry, label) do
    unless is_map(entry), do: raise_arg("#{label} must be a table")
    nonempty_string?(entry[:id]) || raise_arg("#{label}.id must be a non-empty string")

    if entry[:plugin_module] != nil do
      nonempty_string?(entry[:plugin_module]) || raise_arg("#{label}.plugin_module must be a non-empty string")
    end

    Enum.each([:requires, :lazyvim_extras, :mason_packages], fn field ->
      if entry[field] != nil, do: validate_string_list(entry[field], "#{label}.#{field}")
    end)

    if entry[:language_cases] != nil do
      validate_cases(entry[:language_cases], [:language, :filename, :contents, :client], "#{label}.language_cases")
    end

    if entry[:formatter_cases] != nil do
      validate_cases(entry[:formatter_cases], [:language, :filename, :contents, :expected], "#{label}.formatter_cases")
    end

    entry
  end

  @spec validate([map()]) :: [map()]
  def validate(profile) do
    unless is_list(profile), do: raise_arg("Neovim profile must be a list")

    {_, _} =
      Enum.reduce(profile, {1, MapSet.new()}, fn contribution, {index, ids} ->
        label = "Neovim profile[#{index}]"
        validate_entry(contribution, label)
        MapSet.member?(ids, contribution[:id]) && raise_arg("duplicate Neovim profile contribution: #{contribution[:id]}")
        {index + 1, MapSet.put(ids, contribution[:id])}
      end)

    profile
  end

  @spec validate_spec(map()) :: :ok
  @impl Workstation.Core.Source.Provider
  def validate_spec(spec) do
    order = spec[:order]
    unless is_integer(order) and order > 0, do: raise_arg("Neovim profile recipe requires a positive integer order")
    unless is_map(spec[:entry]), do: raise_arg("Neovim profile recipe requires an entry table")
    validate_entry(spec[:entry], "Neovim profile entry #{spec[:entry][:id] |> to_string()}")
    :ok
  end

  @doc """
  Compose collected intents (graph-ordered `{owner, spec}` records). Returns
  `{source_record, profile}` — the attributed chezmoi record this capability
  contributes (owner: nvim, the record's own package) and the composed
  profile entries; owners keep collection order — attribution is a fact
  about contribution, not sorted output.
  """
  @impl Workstation.Core.Source.Provider
  @spec compose([%{required(:owner) => String.t(), required(:spec) => map()}]) ::
          {map(), [map()]}
  def compose(intents) when is_list(intents) do
    intents != [] || raise_arg("Neovim profile composition requires at least one intent")

    Enum.each(intents, fn intent -> validate_spec(intent.spec) end)

    owners = Enum.map(intents, & &1.owner)

    profile =
      intents
      |> Enum.with_index(1)
      |> Enum.sort_by(fn {intent, sequence} -> {intent.spec[:order], sequence} end)
      |> Enum.map(fn {intent, _sequence} -> intent.spec[:entry] end)

    validate(profile)

    recipe =
      Workstation.Core.Source.Chezmoi.recipe(%{target: @target, kind: :file, content: serialize(profile)})

    record = %{owner: "nvim", provider: "chezmoi", spec: recipe, attribution: owners}

    {record, profile}
  end

  # --- serialization (byte parity with profile.lua M.serialize) ---

  @doc """
  Serialize the composed profile as deployed runtime Lua. The deployed file is
  plain editor configuration: no factories, lifecycle modules or engine
  imports.
  """
  @spec serialize([map()]) :: String.t()
  def serialize(profile) do
    validate(profile)

    blocks =
      Enum.map(profile, fn contribution ->
        fields = [
          ["\t\tid = " <> lua_quote(contribution[:id])],
          if contribution[:requires] != nil do
            ["\t\trequires = " <> serialize_list(contribution[:requires])]
          else
            []
          end,
          if contribution[:lazyvim_extras] != nil do
            ["\t\tlazyvim_extras = " <> serialize_list(contribution[:lazyvim_extras])]
          else
            []
          end,
          if contribution[:plugin_module] != nil do
            ["\t\tplugin_module = " <> lua_quote(contribution[:plugin_module])]
          else
            []
          end,
          if contribution[:mason_packages] != nil do
            ["\t\tmason_packages = " <> serialize_list(contribution[:mason_packages])]
          else
            []
          end,
          if contribution[:language_cases] != nil do
            [
              "\t\tlanguage_cases = " <>
                serialize_cases(contribution[:language_cases], [:language, :filename, :contents, :client])
            ]
          else
            []
          end,
          if contribution[:formatter_cases] != nil do
            [
              "\t\tformatter_cases = " <>
                serialize_cases(contribution[:formatter_cases], [:language, :filename, :contents, :expected])
            ]
          else
            []
          end
        ]

        "\t{\n" <> Enum.join(List.flatten(fields), ",\n") <> "\n\t},"
      end)

    "return {\n" <> Enum.join(blocks, "\n") <> "\n}\n"
  end

  defp validate_string_list(values, label) when is_list(values) do
    Enum.with_index(values, 1)
    |> Enum.each(fn {value, index} ->
      nonempty_string?(value) || raise_arg("#{label}[#{index}] must be a non-empty string")
    end)

    :ok
  end

  defp validate_string_list(_values, label), do: raise_arg("#{label} must be a list")

  defp validate_cases(cases, fields, label) when is_list(cases) do
    Enum.with_index(cases, 1)
    |> Enum.each(fn {case, index} ->
      unless is_map(case), do: raise_arg("#{label}[#{index}] must be a table")

      Enum.each(fields, fn field ->
        nonempty_string?(case[field]) || raise_arg("#{label}[#{index}].#{field} must be a non-empty string")
      end)
    end)

    :ok
  end

  defp validate_cases(_cases, _fields, label), do: raise_arg("#{label} must be a list")

  # Lua %q string quoting, matching the recorded fold: `"` -> `\"`,
  # `\` -> `\\`, newline -> literal `\n` (the recorder folds %q's
  # backslash-newline onto one line), other control bytes and DEL -> unpadded
  # decimal escapes, everything else (including UTF-8 bytes) raw.
  defp lua_quote(value) when is_binary(value) do
    escaped =
      for <<byte::8 <- value>>, into: "" do
        cond do
          byte == ?" -> "\\\""
          byte == ?\\ -> "\\\\"
          byte == ?\n -> "\\n"
          byte >= 32 and byte != 127 -> <<byte>>
          true -> "\\#{byte}"
        end
      end

    "\"" <> escaped <> "\""
  end

  defp serialize_list(values) do
    "{ " <> Enum.map_join(values, ", ", &lua_quote/1) <> " }"
  end

  defp serialize_key(name) do
    # Lua %w is ASCII-only: a plain identifier key stays bare, anything else
    # is bracketed and quoted.
    if Regex.match?(~r/^[0-9A-Za-z_]+$/, name) do
      name
    else
      "[" <> lua_quote(name) <> "]"
    end
  end

  defp serialize_case(case, fields) do
    parts = Enum.map(fields, fn field -> "#{field} = " <> lua_quote(case[field]) end)

    parts =
      if case[:project_files] != nil do
        names = Enum.sort(Map.keys(case[:project_files]))

        entries =
          Enum.map(names, fn name -> serialize_key(name) <> " = " <> lua_quote(case[:project_files][name]) end)

        parts ++ ["project_files = { " <> Enum.join(entries, ", ") <> " }"]
      else
        parts
      end

    "{ " <> Enum.join(parts, ", ") <> " }"
  end

  defp serialize_cases(cases, fields) do
    lines = Enum.map(cases, fn case -> "\t\t\t" <> serialize_case(case, fields) <> "," end)
    "{\n" <> Enum.join(lines, "\n") <> "\n\t\t}"
  end

  defp nonempty_string?(value), do: is_binary(value) and value != ""

  defp raise_arg(message), do: raise(ArgumentError, message)

  # --- declared-intent denormalization (atom-keyed, contribute/2 input) ---

  defp denormalize_entry(raw) do
    %{
      id: Map.get(raw, :id),
      requires: Map.get(raw, :requires),
      lazyvim_extras: Map.get(raw, :lazyvim_extras),
      plugin_module: Map.get(raw, :plugin_module),
      mason_packages: Map.get(raw, :mason_packages),
      language_cases:
        declared_cases(Map.get(raw, :language_cases), [:language, :filename, :contents, :client]),
      formatter_cases:
        declared_cases(Map.get(raw, :formatter_cases), [:language, :filename, :contents, :expected])
    }
  end

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

  # --- recorded-envelope denormalization (string-keyed, denormalize_spec/1 input) ---

  defp denormalize_recorded_entry(raw) do
    unless is_map(raw), do: raise_arg("nvim-profile entry must be a table")

    %{
      id: raw["id"],
      requires: copy_string_list(raw["requires"]),
      lazyvim_extras: copy_string_list(raw["lazyvim_extras"]),
      plugin_module: raw["plugin_module"],
      mason_packages: copy_string_list(raw["mason_packages"]),
      language_cases:
        copy_cases(raw["language_cases"], [:language, :filename, :contents, :client]),
      formatter_cases:
        copy_cases(raw["formatter_cases"], [:language, :filename, :contents, :expected])
    }
  end

  defp copy_cases(nil, _fields), do: nil

  defp copy_cases(cases, fields) when is_list(cases) do
    Enum.map(cases, fn case ->
      unless is_map(case), do: raise_arg("nvim-profile case must be a table")

      base =
        Map.new(fields, fn field -> {field, require_nonempty(case, Atom.to_string(field))} end)

      if Map.has_key?(case, "project_files") do
        files = case["project_files"]
        unless is_map(files), do: raise_arg("nvim-profile project_files must be a table")
        Map.put(base, :project_files, files)
      else
        base
      end
    end)
  end

  defp copy_cases(_cases, _fields), do: raise_arg("nvim-profile cases must be a list")

  defp copy_string_list(nil), do: nil

  defp copy_string_list(values) when is_list(values) do
    Enum.each(
      values,
      &(nonempty_string?(&1) || raise_arg("nvim-profile list values must be non-empty strings"))
    )

    values
  end

  defp copy_string_list(_values), do: raise_arg("nvim-profile list must be a list")

  defp require_nonempty(map, field) do
    value = Map.get(map, field)
    nonempty_string?(value) || raise_arg("nvim-profile case #{field} must be a non-empty string")
    value
  end
end
