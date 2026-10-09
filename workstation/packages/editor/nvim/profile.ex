defmodule Workstation.Packages.Nvim.Profile do
  @moduledoc """
  The nvim capability's own profile compositor, owned by its package module:
  collects nvim-profile intents, fixes their order, and serializes the
  shared deployed profile file. Implements the generic
  `Workstation.Core.Contracts.Provider` contract, so the assembler discovers
  and dispatches it without naming this capability — dependency direction:
  consumer package -> provider contract, never the engine -> the consumer.

  The generic machinery — the canonical profile-intent envelope (the
  shape language intents declare), shape-driven entry validation, the
  declared/recorded normalization twins, composition ordering and
  duplicate-id rejection — is the profile platform
  (`Workstation.Core.Platform.Profile`); this module owns the nvim
  semantics: the serialized deployed file's format, and the composition of
  validated nvim-profile intents into ONE attributed chezmoi recipe for
  the shared deployed profile. Sibling language manifests declare their
  intents against the platform envelope directly and name this capability's
  provider id as data — they import nothing from nvim. Contributors keep
  fragment attribution; the compositor never fabricates per-fragment file
  ownership.

  `serialize/1` emits the deployed file as plain editor configuration Lua,
  quoted with Lua `%q` semantics (decimal escapes for control bytes, raw
  UTF-8, literal backslash-n for newlines after the recorder's one-line
  fold); the exact byte shape is pinned by the golden replay tests.
  """

  @behaviour Workstation.Core.Contracts.Provider

  alias Workstation.Core.Platform.Profile
  alias Workstation.Backends.Chezmoi

  @target ".config/nvim/lua/languages/profile.lua"

  # The nvim field vocabulary IS the platform's canonical profile-intent
  # envelope (see Platform.Profile.intent_shape/0) — declared once, in the
  # manifest contract, so sibling language intents never import nvim to
  # reach it.
  @shape Profile.intent_shape()

  @impl Workstation.Core.Contracts.Provider
  def id, do: "nvim-profile"

  @doc """
  One nvim-profile language intent
  as declared by the nvim package module. The raw intent map is normalized
  by the profile platform to the envelope's denormalized shape — every
  declared entry field present (nil when the language omits it), case
  records carrying exactly their base fields plus optional string-keyed
  project_files — so native intents compare equal to the recorded envelope
  and validate through the compositor's own entry validator.
  """
  @spec contribute(pos_integer(), map()) :: %{provider: String.t(), spec: map()}
  def contribute(order, raw), do: Profile.contribution(id(), order, raw)

  @impl Workstation.Core.Contracts.Provider
  @doc """
  Denormalize one recorded-envelope spec (string-keyed golden bytes) back
  to the declared atom shape via the profile platform: known entry fields to
  atom keys, project_files keys staying data (file names, never structure).
  Unknown fields are tolerated: the validator checks known fields without an
  allowlist.
  """
  def denormalize_spec(spec), do: Profile.recorded_spec(spec, @shape, "nvim-profile")

  @spec validate_entry(term(), String.t()) :: map()
  def validate_entry(entry, label), do: Profile.validate_entry(entry, @shape, label)

  @spec validate([map()]) :: [map()]
  def validate(profile), do: Profile.validate_profile(profile, @shape, "Neovim profile")

  @spec validate_spec(map()) :: :ok
  @impl Workstation.Core.Contracts.Provider
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
  about contribution, not sorted output. Ordering, per-entry validation and
  duplicate-id rejection are the profile platform's law; the nvim-owned
  surface is the empty-intent refusal and the serialized recipe.
  """
  @impl Workstation.Core.Contracts.Provider
  @spec compose([%{required(:owner) => String.t(), required(:spec) => map()}]) ::
          {map(), [map()]}
  def compose(intents) when is_list(intents) do
    intents != [] || raise_arg("Neovim profile composition requires at least one intent")

    Enum.each(intents, fn intent -> validate_spec(intent.spec) end)

    owners = Enum.map(intents, & &1.owner)
    profile = Profile.order_intents(intents)

    validate(profile)

    recipe =
      Chezmoi.recipe(%{target: @target, kind: :file, content: serialize(profile)})

    record = %{owner: "nvim", provider: "chezmoi", spec: recipe, attribution: owners}

    {record, profile}
  end

  # --- serialization (the deployed file's exact byte shape; nvim-owned) ---

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

  # Lua %q string quoting, matching the recorded fold: `"` -> `\"`,
  # `\\` -> `\\\\`, newline -> literal `\\n` (the recorder folds %q's
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

  defp raise_arg(message), do: raise(ArgumentError, message)
end
