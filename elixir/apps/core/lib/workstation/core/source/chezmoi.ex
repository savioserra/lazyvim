defmodule Workstation.Core.Source.Chezmoi do
  @moduledoc """
  The chezmoi provider: interprets capability-owned recipe options as native
  chezmoi source state.

  Recipe construction is pure data only; name encoding happens here at
  consumption time. Chezmoi itself renders templates and executes modifiers;
  this module never renders template syntax, decodes source names or executes
  anything.

  Source-name encoding is one-way (`dot_config`, `modify_executable_dot_bashrc`)
  and deliberately decoder-free: a logical component that the backend would
  re-interpret as an attribute (`dot_profile`, `modify_tool`) is rejected
  fail-closed instead of guessed at, so native-name collisions can never hide
  an encoding ambiguity.
  """

  defstruct [
    :target,
    :components,
    :kind,
    :executable,
    :private,
    :exact,
    :template,
    :content,
    :asset,
    :to
  ]

  @type kind :: :file | :directory | :symlink | :modify | :remove

  @type t :: %__MODULE__{
          target: String.t(),
          components: [String.t()],
          kind: kind(),
          executable: boolean() | nil,
          private: boolean() | nil,
          exact: boolean() | nil,
          template: boolean() | nil,
          content: String.t() | nil,
          asset: String.t() | nil,
          to: String.t() | nil
        }

  @kinds [:file, :directory, :symlink, :modify, :remove]

  @allowed_options [:target, :kind, :content, :asset, :executable, :private, :exact, :template, :to]

  # Chezmoi attribute keywords change the decoded kind/target of a source name.
  # A literal logical component that already carries one of these prefixes would
  # be re-interpreted by the backend (for example a home file literally named
  # "dot_profile" or "modify_tool"), so such components are rejected fail-closed
  # instead of guessed at. No decoder is implemented.
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

  @spec validate_options(map()) :: :ok
  def validate_options(options) do
    unless is_map(options), do: raise_arg("chezmoi recipe requires an options table")

    # Structured fragments are the shell compositor's input alone: accepting
    # them here would publish an empty modify program and truncate the target.
    if Map.has_key?(options, :fragments) do
      raise_arg("chezmoi recipe rejects structured fragments: they belong to provision.shell only")
    end

    for field <- Map.keys(options) do
      unless field in @allowed_options do
        raise_arg("chezmoi recipe has unknown option #{inspect(field)}")
      end
    end

    target = Map.get(options, :target)
    kind = Map.get(options, :kind)
    content = Map.get(options, :content)
    asset = Map.get(options, :asset)
    executable = Map.get(options, :executable)
    private = Map.get(options, :private)
    exact = Map.get(options, :exact)
    template = Map.get(options, :template)
    to = Map.get(options, :to)

    nonempty_string?(target) || raise_arg("chezmoi recipe requires a target")
    kind in @kinds || raise_arg("chezmoi recipe has unsupported kind #{inspect(kind)}")

    if content != nil, do: nonempty_string?(content) || raise_arg("chezmoi recipe content must be a non-empty string")

    if asset != nil, do: nonempty_string?(asset) || raise_arg("chezmoi recipe asset must be a non-empty string")

    for {flag, value} <- [executable: executable, private: private, exact: exact, template: template] do
      unless value == nil or is_boolean(value) do
        raise_arg("chezmoi recipe #{flag} must be boolean")
      end
    end

    if content != nil and asset != nil do
      raise_arg("chezmoi recipe accepts exactly one inline body or package-relative asset")
    end

    if to != nil, do: nonempty_string?(to) || raise_arg("chezmoi symlink recipe requires a non-empty link destination")
    if to != nil and kind != :symlink, do: raise_arg("chezmoi recipe option to is only valid for symlinks")

    if kind == :symlink do
      (to != nil and content == nil and asset == nil) ||
        raise_arg("chezmoi symlink recipe requires exactly a link destination")
    end

    case kind do
      :modify ->
        (content != nil or asset != nil) ||
          raise_arg("chezmoi modify recipe requires one whole body or package-relative asset")

      :remove ->
        (content == nil and asset == nil) || raise_arg("chezmoi removal recipe accepts no content")

      _ ->
        (kind == :symlink or kind == :directory or content != nil or asset != nil) ||
          raise_arg("chezmoi recipe requires content or a package-relative asset")
    end

    if executable != nil and executable != true do
      raise_arg("chezmoi recipe executable cannot be disabled; remove the option")
    end

    if kind != :symlink and private != nil and private != true do
      raise_arg("chezmoi recipe private cannot be disabled; remove the option")
    end

    if kind != :symlink and exact != nil and exact != true do
      raise_arg("chezmoi recipe exact cannot be disabled; remove the option")
    end

    if kind != :directory and exact != nil do
      raise_arg("chezmoi recipe exact is only representable for directories")
    end

    if kind == :symlink and (executable != nil or private != nil) do
      raise_arg("chezmoi symlinks take no executable or private attributes")
    end

    if kind == :remove and (executable != nil or private != nil or template != nil) do
      raise_arg("chezmoi removals take no attributes")
    end

    if kind == :directory and template != nil do
      raise_arg("chezmoi directories cannot be templates")
    end

    :ok
  end

  @doc """
  Pure recipe constructor: `Chezmoi.recipe/1`. Returns copied plain data
  without I/O, target writes or registration, with components re-derived from
  the normalized target exactly as at collection time.
  """
  @spec recipe(map()) :: t()
  def recipe(options) do
    :ok = validate_options(options)
    {components, normalized} = normalize_target(Map.fetch!(options, :target))

    count = length(components)

    components
    |> Enum.with_index(1)
    |> Enum.each(fn {component, index} ->
      source_component(component, index == count, Map.get(options, :template) == true)
    end)

    to = Map.get(options, :to)

    if Map.get(options, :kind) == :symlink and to != nil and not String.starts_with?(to, "/") do
      # Declared destinations may be absolute anywhere without being
      # dereferenced here, but relative destinations must resolve inside the
      # destination home rather than escaping it.
      depth = count - 1

      escaped? =
        to
        |> String.split("/", trim: true)
        |> Enum.reduce_while(depth, fn
          "..", depth ->
            if depth - 1 < 0, do: {:halt, true}, else: {:cont, depth - 1}

          _component, depth ->
            {:cont, depth}
        end)

      if escaped? == true, do: raise_arg("chezmoi symlink destination escapes the destination home: #{to}")
    end

    %__MODULE__{
      target: normalized,
      components: components,
      kind: Map.fetch!(options, :kind),
      executable: Map.get(options, :executable),
      private: Map.get(options, :private),
      exact: Map.get(options, :exact),
      template: Map.get(options, :template),
      content: Map.get(options, :content),
      asset: Map.get(options, :asset),
      to: to
    }
  end

  @doc """
  Normalize a logical target to a clean relative home path. Control bytes,
  backslashes, newlines and trailing slashes are rejected: they cannot survive
  into generated source names or literal removal entries. Returns
  `{components, normalized}`.
  """
  @spec normalize_target(term()) :: {[String.t()], String.t()}
  def normalize_target(target) do
    nonempty_string?(target) || raise_arg("chezmoi recipe requires a target string")
    String.starts_with?(target, "/") && raise_arg("chezmoi target must be relative to the destination home: #{target}")
    String.contains?(target, "\\") && raise_arg("chezmoi target must not contain backslashes: #{target}")
    String.ends_with?(target, "/") && raise_arg("chezmoi target must name a file, not a directory slash: #{target}")

    if String.match?(target, control_matcher()) do
      raise_arg("chezmoi target must not contain control characters or newlines: #{target}")
    end

    components = String.split(target, "/", trim: true)

    Enum.each(components, fn component ->
      component in [".", ".."] && raise_arg("chezmoi target must not traverse: #{target}")
    end)

    components != [] || raise_arg("chezmoi target is empty")
    {components, target}
  end

  defp control_matcher, do: ~r/[\x00-\x1f\x7f]/

  @doc """
  Encode one native chezmoi source name component from a logical target
  component. One-way only: conflicts are keyed on normalized targets, never on
  decoded names. A leading dot becomes `dot_`; reserved attribute prefixes and
  a `.tmpl` suffix on anything but the intended final template component are
  rejected.
  """
  @spec source_component(String.t(), boolean(), boolean()) :: String.t()
  def source_component("." <> rest, _is_final, _template), do: "dot_" <> rest

  def source_component(component, is_final, template) when is_binary(component) do
    reserved = Enum.find(@reserved_component_prefixes, &String.starts_with?(component, &1))

    if reserved != nil do
      raise_arg(
        "chezmoi target component #{inspect(component)} is not representable as native source state (reserved prefix #{reserved})"
      )
    end

    if String.ends_with?(component, ".tmpl") do
      unless is_final and template do
        raise_arg(
          "chezmoi target component ending in .tmpl is only representable as the intended template itself: #{component}"
        )
      end
    end

    component
  end

  @doc "Provider id for the chezmoi file backend on the plan wire."
  def provider_id, do: "chezmoi"

  @doc "Provider id for the backend's data-envelope contribution."
  def data_provider_id, do: "chezmoi-data"

  @doc "Engine source-root tombstone filename; part of the backend contract."
  def remove_filename, do: ".chezmoiremove"

  @doc "Engine source-root data-envelope filename; part of the backend contract."
  def data_filename, do: ".chezmoidata.toml"

  @doc """
  Native chezmoi source path for a validated spec, e.g. `.profile` + modify +
  executable -> `modify_executable_dot_profile`. `ancestors` maps an
  intermediate logical target to the attribute flags of its declared owning
  directory recipe, so children of a private directory encode `private_` on
  that component exactly as chezmoi source names require. Removals have no
  source name; they become `.chezmoiremove` entries.
  """
  @spec source_name(t(), %{optional(String.t()) => %{optional(:exact | :private) => boolean()}}) ::
          String.t()
  def source_name(%__MODULE__{kind: :remove}, _ancestors) do
    raise_arg("removal recipes have no chezmoi source name")
  end

  def source_name(%__MODULE__{} = spec, ancestors) do
    ancestors = ancestors || %{}
    [_last | directory] = Enum.reverse(spec.components)

    directory =
      directory
      |> Enum.reverse()
      |> Enum.map_reduce("", fn component, walked ->
        walked = if walked == "", do: component, else: walked <> "/" <> component
        flags = Map.get(ancestors, walked) || %{}

        flags_name =
          if Map.get(flags, :exact) == true, do: "exact_", else: ""

        flags_name =
          if Map.get(flags, :private) == true, do: flags_name <> "private_", else: flags_name

        {flags_name <> source_component(component, false, false), walked}
      end)
      |> elem(0)

    last = source_component(List.last(spec.components), true, spec.template == true)

    unless spec.template == true or not String.ends_with?(last, ".tmpl") do
      raise_arg("chezmoi target ending in .tmpl requires template = true: #{spec.target}")
    end

    flags =
      cond do
        spec.kind == :symlink ->
          ["symlink"]

        spec.kind == :directory ->
          Enum.filter([spec.exact == true && "exact", spec.private == true && "private"], & &1)

        true ->
          Enum.filter([spec.private == true && "private", spec.executable == true && "executable"], & &1)
      end

    prefix = if spec.kind == :modify, do: "modify_", else: ""
    prefix = if flags != [], do: prefix <> Enum.join(flags, "_") <> "_", else: prefix
    suffix = if spec.template == true, do: ".tmpl", else: ""
    head = if directory != [], do: Enum.join(directory, "/") <> "/", else: ""
    head <> prefix <> last <> suffix
  end

  @doc """
  Full required mode metadata for change sets; chezmoi only distinguishes
  private/executable, and arbitrary POSIX modes are rejected as
  unrepresentable. Proven with the trusted backend: private files are 0o600,
  executable files 0o755, and private+executable files 0o700 (owner-only,
  never group/world).
  """
  @spec entry_mode(t()) :: non_neg_integer() | nil
  def entry_mode(%__MODULE__{kind: :symlink}), do: nil
  def entry_mode(%__MODULE__{kind: :directory, private: true}), do: 448
  def entry_mode(%__MODULE__{kind: :directory}), do: 493

  def entry_mode(%__MODULE__{} = spec) do
    cond do
      spec.executable == true -> if spec.private == true, do: 448, else: 493
      spec.private == true -> 384
      true -> 420
    end
  end

  @doc """
  Deep domain validation of a rebuilt spec at consumption time: a mutated or
  hand-built spec cannot redirect the generated path, because every derived
  component must still re-derive from the logical target.
  """
  @spec validate_spec(t()) :: :ok
  def validate_spec(%__MODULE__{} = spec) do
    :ok =
      validate_options(%{
        target: spec.target,
        kind: spec.kind,
        content: spec.content,
        asset: spec.asset,
        executable: spec.executable,
        private: spec.private,
        exact: spec.exact,
        template: spec.template,
        to: spec.to
      })

    {components, normalized} = normalize_target(spec.target)
    normalized == spec.target || raise_arg("chezmoi target is not normalized: #{inspect(spec.target)}")
    components == spec.components || raise_arg("chezmoi target components changed")
    :ok
  end

  defp nonempty_string?(value), do: is_binary(value) and value != ""

  defp raise_arg(message), do: raise(ArgumentError, message)
end
