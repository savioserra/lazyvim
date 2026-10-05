defmodule Workstation.Core.Catalog.Packages do
  @moduledoc """
  The native package catalog registry: one pure-data contribution module
  per workstation package.

  Why a registry of data modules: the plan pipeline (`Catalog.native ->
  Graph.order -> Source.plan`) must compose the workstation's desired state
  without evaluating any Lua, so every package declares its contribution
  (recipes, requirements, options, assets) as pure data.
  `CatalogNativeTest` is the drift anchor that fails the moment a declared
  contribution drifts from the committed golden recording (fragment bytes,
  asset targets, option flags, declaration order).

  Declaration order is load-bearing twice: it is the graph's tie-break for
  equal-priority contributors (`Workstation.Core.Graph` post-order DFS), and
  it is the recorded construction order of the golden envelopes. Parity
  anchor for the recorded order: `workstation/lua/workstation/catalog.lua`
  (deleted with the retired runtime); the editor capability (`Nvim`)
  completes the set.

  The recipe helpers mirror `workstation/lua/workstation/provision/recipes.lua`
  (chezmoi / shell) plus the two domain compositors their contributors import
  directly from their owning packages in Lua (nvim-profile intents, the theme
  chezmoidata envelope). Asset references stay package-relative exactly like
  the Lua factories; `Workstation.Core.Catalog.package_asset!/2` and the
  golden generator are the places that resolve them to bytes, so composition
  stays pure data.
  """

  alias Workstation.Core.Source.{Chezmoi, NvimProfile, Shell}

  # Package modules are referenced by alias here because unqualified atoms
  # inside a module attribute would resolve against the top-level namespace
  # and silently miss Workstation.Core.Catalog.Packages.* at runtime.
  alias Workstation.Core.Catalog.Packages.{
    Agent,
    ElixirLang,
    Fonts,
    Foundation,
    Go,
    Herdr,
    HerdrPi,
    Node,
    Nvim,
    PiNtfyNotifier,
    PiSkills,
    Secrets,
    Theme,
    Tmux,
    Typescript
  }

  # Declaration order is load-bearing (nvim between secrets and typescript):
  # graph ties among foundation's children follow this order, and theme must
  # stay a dependent.
  @package_modules [
    Foundation,
    Fonts,
    Node,
    Agent,
    PiSkills,
    PiNtfyNotifier,
    Go,
    Herdr,
    HerdrPi,
    Secrets,
    Nvim,
    Typescript,
    ElixirLang,
    Theme,
    Tmux
  ]

  @doc "Native package modules in catalog declaration order (the complete catalog)."
  @spec modules() :: [module()]
  def modules, do: @package_modules

  # The catalog taxonomy: every package declares the foundation layer it
  # belongs to (`foundation: "foundation/<layer>"` in its spec map). The
  # declaration is descriptive metadata — it never enters graph resolution,
  # plan projection, or the golden envelopes, so catalog order and plan
  # bytes stay untouched. `CatalogNativeTest` pins the map and the known
  # layer set.
  @known_foundations ~w(
    foundation/base
    foundation/editor
    foundation/runtime
    foundation/terminal
    foundation/agent
    foundation/theme
    foundation/fonts
    foundation/secrets
  )

  @doc "Package id -> declared foundation layer, in declaration order."
  @spec taxonomy() :: %{String.t() => String.t()}
  def taxonomy do
    Map.new(packages(), fn spec ->
      foundation = Map.fetch!(spec, :foundation)
      foundation in @known_foundations || raise "unknown foundation #{foundation}"
      {Map.fetch!(spec, :id), foundation}
    end)
  end

  @doc """
  The native catalog's package specifications in declaration order: the
  materialize.specifications surface of the Lua engine (id, requires,
  supported_hosts, contributes), with contributes validated by their owning
  recipe constructors.
  """
  @spec packages() :: [map()]
  def packages, do: Enum.map(modules(), & &1.spec())

  # --- recipe helpers (parity anchors of provision/recipes.lua + domain compositors) ---

  @doc "One shared-shell fragment contribution (`provision.shell`)."
  @spec shell(String.t(), map()) :: %{provider: String.t(), spec: Shell.t()}
  def shell(target, fragment) do
    %{provider: "shell", spec: Shell.recipe(%{target: target, fragment: fragment})}
  end

  @doc "One chezmoi backend contribution (`provision.chezmoi`); assets stay package-relative."
  @spec chezmoi(keyword()) :: %{provider: String.t(), spec: Chezmoi.t()}
  def chezmoi(options) do
    %{provider: "chezmoi", spec: Chezmoi.recipe(Map.new(options))}
  end

  @doc "The theme capability's chezmoidata envelope, rendered from the canonical tokens."
  @spec theme_data() :: %{provider: String.t(), spec: %{content: String.t()}}
  def theme_data do
    %{provider: "chezmoi-data", spec: %{content: Workstation.Core.Theme.Tokens.chezmoidata()}}
  end

  @doc """
  One nvim-profile language intent (`packages/nvim/profile.lua` recipe). The
  raw intent map is normalized to the envelope's denormalized shape here —
  every declared entry field present (nil when the language omits it), case
  records carrying exactly their base fields plus optional string-keyed
  project_files — so native intents compare equal to the recorded envelope
  and validate through the compositor's own entry validator.
  """
  @spec profile_intent(pos_integer(), map()) :: %{provider: String.t(), spec: map()}
  def profile_intent(order, raw) do
    spec = %{order: order, entry: denormalize_entry(raw)}
    :ok = NvimProfile.validate_spec(spec)
    %{provider: "nvim-profile", spec: spec}
  end

  defp denormalize_entry(raw) do
    %{
      id: Map.get(raw, :id),
      requires: Map.get(raw, :requires),
      lazyvim_extras: Map.get(raw, :lazyvim_extras),
      plugin_module: Map.get(raw, :plugin_module),
      mason_packages: Map.get(raw, :mason_packages),
      language_cases:
        cases(Map.get(raw, :language_cases), [:language, :filename, :contents, :client]),
      formatter_cases:
        cases(Map.get(raw, :formatter_cases), [:language, :filename, :contents, :expected])
    }
  end

  defp cases(nil, _fields), do: nil

  defp cases(list, fields) when is_list(list) do
    Enum.map(list, fn entry ->
      base = Map.new(fields, fn field -> {field, Map.fetch!(entry, field)} end)

      case Map.fetch(entry, :project_files) do
        {:ok, files} -> Map.put(base, :project_files, files)
        :error -> base
      end
    end)
  end
end
