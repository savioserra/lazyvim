defmodule Workstation.Core.SourceName do
  @moduledoc """
  The chezmoi provider: interprets capability-owned recipe options as native
  chezmoi source state. Generated source names are byte-for-byte
  load-bearing — they enter generation digests, change sets and
  precondition baselines — and must stay identical to the names the
  deployed Lua serving path derives (`workstation/lua/workstation/provision/
  chezmoi.lua` parity anchor).

  Recipe construction is pure data only: validation,
  name encoding and asset reading happen here at consumption time, while
  chezmoi itself renders templates and executes modifiers. This module never
  renders template syntax, never decodes source names back to targets, and
  never executes anything.

  Validation failures raise `ArgumentError` exactly where the anchor
  `assert`s: construction failures are engine-level errors with anchored
  messages, not recoverable values.
  """

  alias Workstation.Core.EngineState

  @kinds ["file", "directory", "symlink", "modify", "remove"]

  @reserved_component_prefixes [
    "dot_",
    "create_",
    "modify_",
    "once_",
    "run_",
    "private_",
    "executable_",
    "symlink_",
    "exact_",
    "remove_",
    "empty_",
    "encrypted_"
  ]

  @doc "Reserved chezmoi attribute prefixes; exposed for tests and audits."
  @spec reserved_component_prefixes() :: [String.t()]
  def reserved_component_prefixes, do: @reserved_component_prefixes

  defp nonempty_string?(value), do: is_binary(value) and value != ""

  defp control?(target), do: String.match?(target, ~r/[\x00-\x1f\x7f]/)

  @doc """
  Normalize a logical target to a clean relative home path. Control bytes,
  newlines and NUL are rejected: they cannot survive into generated source
  names or literal removal entries.
  """
  @spec normalize_target(term()) :: {[String.t()], String.t()}
  def normalize_target(target) do
    unless nonempty_string?(target), do: raise(ArgumentError, "chezmoi recipe requires a target string")

    unless not String.starts_with?(target, "/"),
      do: raise(ArgumentError, "chezmoi target must be relative to the destination home: #{target}")

    unless not String.contains?(target, "\\"),
      do: raise(ArgumentError, "chezmoi target must not contain backslashes: #{target}")

    unless not String.ends_with?(target, "/"),
      do: raise(ArgumentError, "chezmoi target must name a file, not a directory slash: #{target}")

    unless not control?(target),
      do: raise(ArgumentError, "chezmoi target must not contain control characters or newlines: #{target}")

    components = String.split(target, "/", trim: true)

    Enum.each(components, fn component ->
      if component in [".", ".."], do: raise(ArgumentError, "chezmoi target must not traverse: #{target}")
    end)

    {components, Enum.join(components, "/")}
  end

  defp validate_options(options) do
    unless is_map(options), do: raise(ArgumentError, "chezmoi recipe requires an options table")

    # Structured fragments are the shell compositor's input alone: accepting
    # them here would publish an empty modify program and truncate the target.
    unless is_nil(options["fragments"]),
      do:
        raise(ArgumentError,
          "chezmoi recipe rejects structured fragments: they belong to provision.shell only"
        )

    allowed = ["target", "kind", "content", "asset", "executable", "private", "exact", "template", "to"]

    Enum.each(Map.keys(options), fn field ->
      unless field in allowed, do: raise(ArgumentError, "chezmoi recipe has unknown option #{inspect(field)}")
    end)

    unless nonempty_string?(options["target"]), do: raise(ArgumentError, "chezmoi recipe requires a target")

    kind = options["kind"]

    unless kind in @kinds, do: raise(ArgumentError, "chezmoi recipe has unsupported kind #{inspect(kind)}")

    unless is_nil(options["content"]) or nonempty_string?(options["content"]),
      do: raise(ArgumentError, "chezmoi recipe content must be a non-empty string")

    unless is_nil(options["asset"]) or nonempty_string?(options["asset"]),
      do: raise(ArgumentError, "chezmoi recipe asset must be a non-empty string")

    Enum.each(["executable", "private", "exact", "template"], fn flag ->
      value = options[flag]

      unless is_nil(value) or is_boolean(value), do: raise(ArgumentError, "chezmoi recipe #{flag} must be boolean")
    end)

    unless is_nil(options["content"]) or is_nil(options["asset"]),
      do: raise(ArgumentError, "chezmoi recipe accepts exactly one inline body or package-relative asset")

    unless is_nil(options["to"]) or nonempty_string?(options["to"]),
      do: raise(ArgumentError, "chezmoi symlink recipe requires a non-empty link destination")

    unless is_nil(options["to"]) or kind == "symlink",
      do: raise(ArgumentError, "chezmoi recipe option to is only valid for symlinks")

    unless kind != "symlink" or (not is_nil(options["to"]) and is_nil(options["content"]) and is_nil(options["asset"])),
      do: raise(ArgumentError, "chezmoi symlink recipe requires exactly a link destination")

    if kind == "modify" do
      unless not is_nil(options["content"]) or not is_nil(options["asset"]),
        do: raise(ArgumentError, "chezmoi modify recipe requires one whole body or package-relative asset")
    end

    if kind == "remove" do
      unless is_nil(options["content"]) and is_nil(options["asset"]),
        do: raise(ArgumentError, "chezmoi removal recipe accepts no content")
    end

    if kind not in ["symlink", "directory", "remove"] do
      unless not is_nil(options["content"]) or not is_nil(options["asset"]),
        do: raise(ArgumentError, "chezmoi recipe requires content or a package-relative asset")
    end

    unless is_nil(options["executable"]) or options["executable"] == true,
      do: raise(ArgumentError, "chezmoi recipe executable cannot be disabled; remove the option")

    unless kind == "symlink" or is_nil(options["private"]) or options["private"] == true,
      do: raise(ArgumentError, "chezmoi recipe private cannot be disabled; remove the option")

    unless kind == "symlink" or is_nil(options["exact"]) or options["exact"] == true,
      do: raise(ArgumentError, "chezmoi recipe exact cannot be disabled; remove the option")

    unless kind == "directory" or is_nil(options["exact"]),
      do: raise(ArgumentError, "chezmoi recipe exact is only representable for directories")

    unless kind != "symlink" or (is_nil(options["executable"]) and is_nil(options["private"])),
      do: raise(ArgumentError, "chezmoi symlinks take no executable or private attributes")

    unless kind != "remove" or (is_nil(options["executable"]) and is_nil(options["private"]) and is_nil(options["template"])),
      do: raise(ArgumentError, "chezmoi removals take no attributes")

    unless kind != "directory" or is_nil(options["template"]),
      do: raise(ArgumentError, "chezmoi directories cannot be templates")
  end

  @doc """
  Pure recipe constructor: `Workstation.Core.SourceName.recipe(options)`.
  Returns copied plain data without I/O, target writes or registration. The
  symlink destination containment check mirrors the anchor: declared
  destinations may be absolute anywhere without being dereferenced here, but
  relative destinations must resolve inside the destination home rather than
  escaping it.
  """
  @spec recipe(map()) :: map()
  def recipe(options) do
    validate_options(options)
    {components, normalized} = normalize_target(options["target"])
    template = options["template"] == true

    Enum.with_index(components, fn component, index ->
      source_component(component, index + 1 == length(components), template)
    end)

    if options["kind"] == "symlink" and not String.starts_with?(options["to"], "/") do
      depth = length(components) - 1

      depth =
        options["to"]
        |> String.split("/", trim: true)
        |> Enum.reduce(depth, fn
          "..", depth -> depth - 1
          _other, depth -> depth
        end)

      unless depth >= 0,
        do: raise(ArgumentError, "chezmoi symlink destination escapes the destination home: #{options["to"]}")
    end

    spec = %{
      "target" => normalized,
      "components" => components,
      "kind" => options["kind"],
      "executable" => options["executable"],
      "private" => options["private"],
      "exact" => options["exact"],
      "template" => options["template"]
    }

    spec =
      cond do
        not is_nil(options["content"]) -> Map.put(spec, "content", options["content"])
        not is_nil(options["asset"]) -> Map.put(spec, "asset", options["asset"])
        true -> spec
      end

    spec = if is_nil(options["to"]), do: spec, else: Map.put(spec, "to", options["to"])

    %{"provider" => "chezmoi", "spec" => spec}
  end

  @doc """
  Encode one native chezmoi source name component from a logical target
  component. Leading dots become the `dot_` prefix; components that already
  carry a reserved attribute prefix are rejected fail-closed — the backend
  would re-interpret them (for example a home file literally named
  `dot_profile` or `modify_tool`), and no decoder is implemented to guess.
  """
  @spec source_component(String.t(), boolean(), boolean()) :: String.t()
  def source_component(component, is_final, template) do
    if String.starts_with?(component, ".") do
      "dot_" <> String.slice(component, 1..-1//1)
    else
      Enum.each(@reserved_component_prefixes, fn prefix ->
        if String.starts_with?(component, prefix) do
          raise(ArgumentError,
            "chezmoi target component #{inspect(component)} is not representable as native source state (reserved prefix #{prefix})"
          )
        end
      end)

      if String.ends_with?(component, ".tmpl") do
        unless is_final and template,
          do:
            raise(ArgumentError,
              "chezmoi target component ending in .tmpl is only representable as the intended template itself: #{component}"
            )
      end

      component
    end
  end

  @doc """
  Native chezmoi source path for a validated spec, e.g. `.profile` + modify +
  executable -> `modify_executable_dot_profile`. `ancestors` maps an
  intermediate logical target to the attribute flags of its declared owning
  directory recipe, so children of a private directory encode `private_` on
  that component exactly as chezmoi source names require. Explicit removals
  have no source name; they become `.chezmoiremove` entries.
  """
  @spec source_name(map(), %{optional(String.t()) => map()}) :: String.t()
  def source_name(spec, ancestors \\ %{})

  def source_name(%{"kind" => "remove"}, _ancestors) do
    raise(ArgumentError, "removal recipes have no chezmoi source name")
  end

  def source_name(spec, ancestors) do
    components = spec["components"]

    # take/2 (not slice with a negative-end range): a single-component target
    # has no directory parts, and `0..-1` would silently wrap to the whole list.
    directory =
      components
      |> Enum.take(length(components) - 1)
      |> Enum.with_index(fn component, index ->
        walked =
          if index == 0 do
            component
          else
            Enum.slice(components, 0..index//1) |> Enum.join("/")
          end

        flags = ancestors[walked] || %{}
        flags_name = ""

        flags_name =
          if flags["exact"], do: flags_name <> "exact_", else: flags_name

        flags_name =
          if flags["private"], do: flags_name <> "private_", else: flags_name

        flags_name <> source_component(component, false, false)
      end)

    last = source_component(List.last(components), true, spec["template"])

    # Lua truthiness (`spec.template or not last:find(...))` treats nil as
    # falsy; Elixir's `not` is strict, so absence must be compared explicitly.
    if spec["template"] != true and String.ends_with?(last, ".tmpl") do
      raise(ArgumentError, "chezmoi target ending in .tmpl requires template = true: #{spec["target"]}")
    end

    flags =
      case spec["kind"] do
        "symlink" ->
          ["symlink"]

        "directory" ->
          Enum.filter(["exact", "private"], fn flag -> spec[flag] end)

        _other ->
          Enum.filter(["private", "executable"], fn flag -> spec[flag] end)
      end

    prefix = if spec["kind"] == "modify", do: "modify_", else: ""

    prefix =
      if flags != [], do: prefix <> Enum.join(flags, "_") <> "_", else: prefix

    suffix = if spec["template"], do: ".tmpl", else: ""

    head = if directory != [], do: Enum.join(directory, "/") <> "/", else: ""
    head <> prefix <> last <> suffix
  end

  @doc """
  Full required mode metadata for change sets; chezmoi only distinguishes
  private/executable, and arbitrary POSIX modes are rejected as
  unrepresentable. Proven with the trusted backend: private files are 0600,
  executable files 0755, and private+executable files 0700 (owner-only, never
  group/world). Symlinks carry no mode.
  """
  @spec entry_mode(map()) :: non_neg_integer() | nil
  def entry_mode(%{"kind" => "symlink"}), do: nil

  def entry_mode(%{"kind" => "directory", "private" => private}) do
    if private, do: 0o700, else: 0o755
  end

  def entry_mode(%{"executable" => true, "private" => private}), do: if(private, do: 0o700, else: 0o755)
  def entry_mode(%{"private" => true}), do: 0o600
  def entry_mode(_spec), do: 0o644

  @doc """
  Read a confined package-relative asset. The asset must stay inside the
  owner root, name only directories and one final regular file, and never
  traverse a symlink out of the declared owning root.
  """
  @spec read_asset(String.t(), term()) :: binary()
  def read_asset(owner_root, asset) do
    unless nonempty_string?(asset), do: raise(ArgumentError, "chezmoi recipe asset must be a non-empty string")

    unless not String.starts_with?(asset, "/"),
      do: raise(ArgumentError, "chezmoi asset must be package-relative: #{asset}")

    components = String.split(asset, "/", trim: true)

    Enum.each(components, fn component ->
      if component in [".", ".."], do: raise(ArgumentError, "chezmoi asset must not traverse: #{asset}")
    end)

    current = Path.join([owner_root | components])

    Enum.reduce(components, owner_root, fn component, acc ->
      acc = Path.join(acc, component)
      info = EngineState.lstat(acc) || raise(ArgumentError, "chezmoi asset is missing: #{owner_root}/#{asset}")

      unless info.type in ["directory", "file"],
        do: raise(ArgumentError, "chezmoi asset component is not a regular entry")

      acc
    end)

    final = EngineState.lstat(current) || raise(ArgumentError, "chezmoi asset is missing: #{owner_root}/#{asset}")

    unless final.type == "file", do: raise(ArgumentError, "chezmoi asset must be a regular file: #{owner_root}/#{asset}")

    contents = File.read!(current)

    unless nonempty_string?(contents), do: raise(ArgumentError, "chezmoi asset is empty: #{owner_root}/#{asset}")

    contents
  end

  @doc """
  Resolve the source bytes for a validated spec, reading a confined asset when
  declared. Returns nil for entries without a body.
  """
  @spec source_bytes(map(), String.t()) :: binary() | nil
  def source_bytes(spec, owner_root) do
    cond do
      not is_nil(spec["content"]) -> spec["content"]
      not is_nil(spec["asset"]) -> read_asset(owner_root, spec["asset"])
      true -> nil
    end
  end

  @doc """
  Deep domain validation of a materialized spec at collection time. A mutated
  or hand-built envelope cannot redirect the generated path: unknown fields
  are rejected and every derived component must still re-derive from the
  logical target.
  """
  @spec validate_spec(term()) :: :ok
  def validate_spec(spec) do
    unless is_map(spec), do: raise(ArgumentError, "chezmoi spec must be a table")
    unless is_binary(spec["target"]), do: raise(ArgumentError, "chezmoi spec requires a target string")

    # Envelope whitelist: a spec is engine-produced, so an unknown field is a
    # mutated envelope that could redirect the generated path or smuggle an
    # unvalidated option past this check.
    allowed = ["target", "components", "kind", "content", "asset", "executable", "private", "exact", "template", "to"]

    Enum.each(Map.keys(spec), fn field ->
      unless field in allowed, do: raise(ArgumentError, "chezmoi spec has unknown field #{inspect(field)}")
    end)

    validate_options(%{
      "target" => spec["target"],
      "kind" => spec["kind"],
      "content" => spec["content"],
      "asset" => spec["asset"],
      "executable" => spec["executable"],
      "private" => spec["private"],
      "exact" => spec["exact"],
      "template" => spec["template"],
      "to" => spec["to"]
    })

    {components, normalized} = normalize_target(spec["target"])

    unless normalized == spec["target"], do: raise(ArgumentError, "chezmoi target is not normalized: #{inspect(spec["target"])}")

    unless is_list(spec["components"]) and length(spec["components"]) == length(components) do
      raise(ArgumentError, "chezmoi target components changed")
    end

    Enum.with_index(components, fn component, index ->
      unless Enum.at(spec["components"], index) == component do
        raise(ArgumentError, "chezmoi target component #{index + 1} does not re-derive from #{spec["target"]}")
      end
    end)

    :ok
  end

  @doc """
  Expected target state for precondition checks, when it is computable from
  the recipe alone: full required mode plus type/content/link identity.
  Template bodies are backend-rendered and return nil.
  """
  @spec expected_state(map(), binary() | nil) :: map() | nil
  def expected_state(%{"template" => true}, _bytes), do: nil

  def expected_state(%{"kind" => "file"} = spec, bytes) do
    %{"type" => "file", "sha256" => EngineState.sha256(bytes), "mode" => entry_mode(spec)}
  end

  def expected_state(%{"kind" => "symlink"} = spec, _bytes) do
    %{"type" => "link", "link" => spec["to"]}
  end

  def expected_state(%{"kind" => "directory"} = spec, _bytes) do
    %{"type" => "directory", "mode" => entry_mode(spec)}
  end

  def expected_state(_spec, _bytes), do: nil
end
