defmodule Workstation.Core.Catalog.Packages do
  @moduledoc """
  The native package catalog: one pure-data contribution module per
  workstation package, DISCOVERED at runtime — there is no registration
  list to edit.

  Why data modules: the plan pipeline (`Catalog.native -> Graph.order ->
  Source.plan`) must compose the workstation's desired state without
  evaluating any Lua, so every package declares its contribution (recipes,
  requirements, options, assets) as pure data. Adding a package means
  dropping a conforming `Workstation.Core.Catalog.Spec` provider under
  this namespace — discovery (`Workstation.Core.Catalog.Discover`) finds
  it via `:code.all_available/0` + behaviour conformance, validates its
  shape, and rejects duplicate ids. `CatalogNativeTest` is the drift
  anchor that fails the moment a declared contribution drifts from the
  committed golden recording (fragment bytes, asset targets, option
  flags).

  Package ordering comes exclusively from `requires`/`after` edges:
  graph ties among dependency-equal packages resolve by id sort, so no
  module's position in any list is load-bearing. Parity anchor for the
  recorded order: `workstation/lua/workstation/catalog.lua` (deleted with
  the retired runtime); the editor capability (`Nvim`) completes the set.

  The recipe helpers mirror `workstation/lua/workstation/provision/recipes.lua`
  (chezmoi / shell) plus the two domain compositors their contributors import
  directly from their owning packages in Lua (nvim-profile intents, the theme
  chezmoidata envelope). Asset references stay package-relative exactly like
  the Lua factories; `Workstation.Core.Catalog.package_asset!/2` and the
  golden generator are the places that resolve them to bytes, so composition
  stays pure data.
  """

  alias Workstation.Core.Catalog.Discover
  alias Workstation.Core.Source.{Chezmoi, NvimProfile, Shell}

  @doc """
  Discovered package-spec provider modules, sorted by module name (the
  complete catalog — there is no registration order).
  """
  @spec modules() :: [module()]
  def modules, do: Discover.providers()

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

  @doc "Package id -> declared foundation layer, in discovery order."
  @spec taxonomy() :: %{String.t() => String.t()}
  def taxonomy do
    Map.new(packages(), fn spec ->
      foundation = Map.fetch!(spec, :foundation)
      foundation in @known_foundations || raise "unknown foundation #{foundation}"
      {Map.fetch!(spec, :id), foundation}
    end)
  end

  @doc """
  The native catalog's package specifications in discovery order (module
  name / id sort): the materialize.specifications surface of the Lua engine
  (id, requires, after, supported_hosts, contributes), with contributes
  validated by their owning recipe constructors. Delegates to
  `Discover.specs/0`, so the contributor contract (spec shape, duplicate
  ids, banned integer-ordering fields) is enforced on the production seam,
  not only on the test one.
  """
  @spec packages() :: [map()]
  def packages, do: Discover.specs()

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
