defmodule Workstation.Core.Catalog do

  # Backend wire ids as compile-time constants: guards cannot call remote
  # functions, and generic core must reference the backend only through its
  # module API (ArchitectureDepsTest enforces the isolation).
  @chezmoi Workstation.Backends.Chezmoi.provider_id()
  alias Workstation.Core.EngineState

  @moduledoc """
  The normalized plan-input envelope — one shape for every catalog source.

  `load/1` takes the decoded `input.json` of a recorded golden profile
  (tests/goldens/<profile>) and rebuilds real engine recipes: chezmoi
  options through `Source.Chezmoi.recipe/1`, shell fragments through
  `Workstation.Core.Contracts.Shell.recipe/1`, the chezmoi-data envelope and capability-provider
  specs dispatched to their owner modules' compositors. Package-relative
  asset bodies recorded in the
  top-level `assets` map are inlined back into the options as `:content`,
  so the plan pipeline never performs filesystem I/O and replay stays a
  pure function of the input bytes.

  `live/1` composes the same envelope from the native package registry
  (`Catalog.Packages`) for engine commands, and `native/1` is its
  destination-neutral recording form — the golden generator's input.
  Byte equivalence between the recorded profiles and the native catalog is
  pinned by `Workstation.Core.CatalogNativeTest` against the committed
  goldens.
  """

  defstruct [:profile, :host, :home, :packages, :assets]

  @type recipe :: %{
          required(:provider) => String.t(),
          required(:spec) =>
            Workstation.Backends.Chezmoi.t()
            | Workstation.Core.Contracts.Shell.t()
            | %{required(:content) => String.t()}
            | %{required(:order) => pos_integer(), required(:entry) => map()}
        }

  @type package :: %{
          required(:id) => String.t(),
          required(:requires) => [String.t()],
          optional(:after) => [String.t()] | nil,
          optional(:supported_hosts) => %{optional(String.t()) => boolean()} | nil,
          optional(:foundation) => String.t(),
          required(:contributes) => [recipe()]
        }

  @type t :: %__MODULE__{
          profile: String.t(),
          host: String.t(),
          home: String.t(),
          packages: [package()],
          assets: %{optional(String.t()) => String.t()}
        }

  # The live envelope's profile marker, never a committed golden profile
  # name. A live envelope pins its symlink destinations to the canonical
  # recording home so replay stays machine-independent; live envelopes
  # re-root those destinations to the served home (the state-root bracket
  # in evaluate/3 or the daemon's served home), which is what makes
  # EngineState.home() the destination truth — without re-rooting, a plan
  # for a real host would stage a /home/golden destination and diverge
  # from the recorded bytes on every host with a home-anchored recipe
  # (invisible to goldens, which pin the canonical bytes on both sides).
  @live_profile "live"

  # The banned design: integer ordering fields on a package spec (the
  # discovery layer rejects them on native declarations through
  # `Workstation.Core.Catalog.Spec.validate!/2`; recorded envelopes are
  # rejected here with the same rule). Ordering between packages comes only
  # from requires/after edges — ties resolve by id sort.
  @banned_spec_keys ~w(order position priority)

  @doc """
  Load and fully denormalize one decoded golden input. Every recipe is
  re-validated by its owning provider constructor at load time, mirroring the
  collection-time guarantee: a hand-baked input cannot bypass domain
  validation because derived fields are re-derived from the logical target.
  """
  @spec load(map()) :: t()
  def load(input) do
    unless is_map(input), do: raise_arg("golden input must be an object")
    profile = require_string(input, "profile")
    host = require_string(input, "host")
    home = require_string(input, "home")
    # Only the live envelope re-roots destinations, and only inside the
    # state-root bracket (evaluate/3 or the daemon's served home), which is
    # what makes EngineState.home() the destination truth here.
    live_home = if profile == @live_profile, do: EngineState.home()
    raw_packages = Map.get(input, "packages")
    unless is_list(raw_packages), do: raise_arg("golden input packages must be a list")

    # A recorded empty assets table is [] (a JSON array, not an object);
    # it replays as an empty map.
    assets =
      case Map.get(input, "assets") do
        nil -> %{}
        [] -> %{}
        assets when is_map(assets) -> assets
        _ -> raise_arg("golden input assets must be an object")
      end

    packages =
      Enum.map(raw_packages, fn raw ->
        unless is_map(raw), do: raise_arg("golden input package must be an object")
        id = require_string(raw, "id")
        requires = Map.get(raw, "requires") || []
        validate_string_list(requires, "#{id}.requires")

        # Ordering-only edges: validated as string lists here; Graph applies
        # them only when the target is present and enabled (no pull-in).
        after_edges = Map.get(raw, "after") || []
        validate_string_list(after_edges, "#{id}.after")

        Enum.each(@banned_spec_keys, fn key ->
          Map.has_key?(raw, key) &&
            raise_arg(
              "#{id} declares \"#{key}\" — integer ordering fields are banned on package " <>
                "specs; order packages with requires/after edges instead (ties resolve by id sort)"
            )
        end)

        supported_hosts =
          case Map.get(raw, "supported_hosts") do
            nil ->
              nil

            hosts ->
              unless is_map(hosts), do: raise_arg("#{id}.supported_hosts must be an object")

              Map.new(hosts, fn {name, supported} ->
                is_boolean(supported) || raise_arg("#{id} has invalid host support")
                {name, supported}
              end)
          end

        raw_contributes = Map.get(raw, "contributes")
        unless is_list(raw_contributes), do: raise_arg("#{id}.contributes must be a list")

        contributes =
          Enum.map(raw_contributes, fn recipe ->
            unless is_map(recipe), do: raise_arg("#{id} contribution must be a table")
            provider = require_string(recipe, "provider")
            spec = Map.get(recipe, "spec")
            unless is_map(spec), do: raise_arg("#{id}.contributes spec must be a table")
            %{provider: provider, spec: denormalize(id, provider, spec, assets, live_home, home)}
          end)

        # Nil-drop convention: an absent/empty after list keeps the loaded
        # package byte-shape equal to a native spec without the key (the
        # envelope records "after" only when declared).
        package = %{
          id: id,
          requires: requires,
          supported_hosts: supported_hosts,
          contributes: contributes
        }

        package = if after_edges == [], do: package, else: Map.put(package, :after, after_edges)
        package = put_context_surface(package, raw, id)

        package
      end)

    %__MODULE__{profile: profile, host: host, home: home, packages: packages, assets: assets}
  end

  ## --- native composition ---

  @doc """
  The running platform's catalog host name — the vocabulary `Graph.order`
  selects on ("linux" / "darwin"). Unsupported platforms fail closed
  instead of silently composing a catalog for a host outside the support
  set.
  """
  @spec native_host() :: String.t()
  def native_host do
    case :os.type() do
      {:unix, :linux} -> "linux"
      {:unix, :darwin} -> "darwin"
      other -> raise ArgumentError, "unsupported platform: #{inspect(other)}"
    end
  end

  @doc """
  The native catalog's declared package specifications, in discovery order
  (module-name / id sort) — the complete capability set (the editor
  capability included):
  package data validated by the recipe constructors, with asset references
  kept package-relative exactly like the declarations declare them.
  Composition semantics (host selection, requires/after graph, topological
  order, cycle and unknown-dependency rejection) live in
  `Workstation.Core.Graph` through `compose/1`.
  """
  @spec native_packages() :: [package()]
  def native_packages, do: Workstation.Core.Catalog.Packages.packages()

  @doc """
  The live executable envelope for one target home: the native catalog with
  the live profile marker, host = the running platform, and every
  home-anchored destination re-rooted from `canonical_home/0` to `home` —
  the same single home substitution point `load/1` applies to recorded live
  envelopes. Engine commands (`status`/`plan`/`diff`, the sync
  reconciliation, the daemon applier's server-side plan) evaluate THIS
  envelope; the home is only a destination, so an empty home still composes
  the complete catalog.
  """
  # The canonical recording home pinned into recorded golden envelopes
  # (docs/elixir.md carries the recording history). Recorded envelopes are
  # machine-independent because every home-anchored destination is rewritten
  # to this path; the one native declaration that carries a home-anchored
  # destination (the editor capability's launcher symlink) anchors at the
  # same path, so
  # envelope replay stays byte-stable across hosts and the live re-rooting
  # branches in load/1 and live/1 remain the only home substitution points.
  @canonical_home "/home/golden"

  @spec live(String.t()) :: t()
  def live(home) when is_binary(home) and home != "" do
    {packages, assets} = inline_assets(native_packages(), %{})

    %__MODULE__{
      profile: @live_profile,
      host: native_host(),
      home: @canonical_home,
      packages: Enum.map(packages, &reroot(&1, home)),
      assets: assets
    }
  end

  # Re-root one home-anchored destination on an already-validated recipe:
  # native declarations anchor at the canonical recording home, and the
  # live envelope moves exactly the destinations under that prefix — the
  # destination-move semantics live in the backend module
  # (Chezmoi.reroot_home/2, dispatch by provider id; the trailing-slash
  # guard keeps a bare canonical home unmangled). Dispatch is generically on provider id through the backend
  # module API — the catalog knows ids, not structs.
  defp reroot(package, live_home) do
    contributes =
      Enum.map(
        package.contributes,
        &Workstation.Backends.Chezmoi.reroot_home(&1, %{from: @canonical_home, to: live_home})
      )

    %{package | contributes: contributes}
  end

  @doc """
  Compose a catalog for one host from pure data: host selection, requires
  graph, topological order, cycle and unknown-dependency rejection — the
  same `Graph.order` semantics the golden replay grades. `:host` is
  required; `:specifications` overrides the package set (the golden
  generator's catalog-profile closures and the equivalence tests compose
  variant sets through this seam, and a missing capability still fails
  closed — the proof that no package is silently guessed).
  """
  @spec compose(keyword()) :: Workstation.Core.Graph.t()
  def compose(opts) do
    Workstation.Core.Graph.order(%{
      host: Keyword.fetch!(opts, :host),
      specifications: Keyword.get(opts, :specifications, native_packages())
    })
  end

  @doc """
  The native executable envelope: declared specs with every package-relative
  asset reference resolved to bytes read from the engine checkout and
  inlined as recipe content (asset dropped, prefixed key recorded in
  `assets`). Why inline here: the plan pipeline is pure — `Source.plan/1`
  reads no package assets — so a native plan run needs the bodies up front,
  and the golden comparison can assert struct equality against `load/1`
  output. Native declarations carry no live-home destinations: the single
  home-anchored destination (the editor capability's launcher symlink)
  anchors at
  `canonical_home/0`, so `live/1` and the live branch of `load/1` remain
  the only home substitution points.
  """
  @spec native(keyword()) :: t()
  def native(opts \\ []) do
    {packages, assets} = inline_assets(native_packages(), %{})

    %__MODULE__{
      profile: Keyword.get(opts, :profile, "native"),
      host: Keyword.get(opts, :host),
      home: Keyword.get(opts, :home),
      packages: packages,
      assets: assets
    }
  end

  @doc "The canonical recording home every recorded golden envelope pins."
  @spec canonical_home() :: String.t()
  def canonical_home, do: @canonical_home

  # Resolve one package's declared assets against the engine checkout. The
  # engine root is the update checkout anchor (bootstrap.pins + versions.json
  # + bin/workstation): without a checkout there is no honest asset source,
  # so resolution fails closed instead of guessing a sibling tree.
  defp inline_assets(packages, assets) do
    Enum.map_reduce(packages, assets, fn package, acc ->
      {contributes, acc} =
        Enum.map_reduce(package.contributes, acc, fn recipe, acc ->
          # Dispatch is generically on provider id: the backend owns the
          # dialect (which field carries the reference, inlining semantics);
          # the catalog owns the one auditable asset read.
          {recipe, inlined} =
            Workstation.Backends.Chezmoi.inline_asset(recipe, fn relative ->
              package_asset!(package.id, relative)
            end)

          acc =
            if inlined do
              {relative, content} = inlined
              Map.put(acc, package.id <> ":" <> relative, content)
            else
              acc
            end

          {recipe, acc}
        end)

      {%{package | contributes: contributes}, acc}
    end)
  end

  @doc """
  Resolve one package's declared asset bytes from the engine checkout —
  package-relative, so native declarations stay pure data and filesystem
  reads happen in one auditable place.

  An empty body is always a recording failure, so asset reads fail closed
  on it.
  """
  @spec package_asset!(String.t(), String.t()) :: String.t()
  def package_asset!(package_id, relative) do
    path = Path.join([Workstation.Core.Update.engine_root([]), "packages", package_id, relative])

    case File.read(path) do
      {:ok, bytes} when bytes != "" ->
        bytes

      _other ->
        raise ArgumentError,
              "native catalog asset is missing or empty: #{package_id}:#{relative} (#{path})"
    end
  end

  # Capability-provider shapes are NOT known here: denormalization dispatches
  # through the `Workstation.Core.Contracts.Provider` contract to the owner
  # package module (discovered, never named), so a new capability provider
  # plugs into golden replay with zero edits to this module. A package-owned
  # recipe kind may carry both handshakes, so the capability surface is
  # consulted first.
  defp denormalize(package_id, provider, spec, assets, live_home, canonical_home) do
    case Workstation.Core.Contracts.Provider.Discover.lookup(provider) do
      {:ok, module} ->
        module.denormalize_spec(spec)

      :error ->
        denormalize_generic(package_id, provider, spec, assets, live_home, canonical_home)
    end
  end

  # Generic recorded shapes dispatch through the discovered contract
  # modules — the same two lines the capability branch uses (lookup + owner
  # call): the catalog knows ids, never dialect bodies. The envelope context
  # is plain data (error attribution, the recorded asset table, the live
  # re-rooting bracket); a contract id without a recorded-shape reader —
  # or an unknown id entirely — fails closed with the provider named.
  defp denormalize_generic(package_id, provider, spec, assets, live_home, canonical_home) do
    case Workstation.Core.Contracts.Contract.Discover.lookup(provider) do
      {:ok, module} ->
        unless function_exported?(module, :from_recorded, 2) do
          raise_arg(
            "#{package_id} golden input declares provider #{inspect(provider)} " <>
              "whose contract reads no recorded shape"
          )
        end

        module.from_recorded(spec, %{
          package_id: package_id,
          assets: assets,
          live_home: live_home,
          canonical_home: canonical_home
        })

      :error ->
        raise_arg("#{package_id} golden input declares unknown provider #{inspect(provider)}")
    end
  end

  # Re-root one symlink destination from the canonical recording home to the
  # live home (see @live_profile). Only destinations UNDER the canonical home
  # move — destinations outside it stay verbatim, and
  # the trailing-slash guard keeps a bare canonical home unmangled.



  # The package-context surface (exports / context_requires): denormalized
  # through the same rules the native spec validation enforces — one export
  # per own-capability key, pure string-keyed values, requirements keyed to
  # DECLARED dependencies, well-formed version ranges. Nil-dropped when
  # absent so profiles without the surface keep their recorded byte-shape.
  defp put_context_surface(package, raw, id) do
    package =
      case Map.get(raw, "exports") do
        nil -> package
        [] -> package
        exports -> Map.put(package, :exports, denormalize_exports(exports, id))
      end

    case Map.get(raw, "context_requires") do
      nil -> package
      [] -> package
      context_requires ->
        Map.put(package, :context_requires, denormalize_context_requires(context_requires, id, package.requires))
    end
  end

  defp denormalize_exports(exports, id) when is_list(exports) do
    validated =
      Enum.map(exports, fn export ->
        unless is_map(export), do: raise_arg("#{id}.exports entries must be objects")

        %{
          key: Workstation.Core.Contracts.Recorded.string!(export, "key", id),
          schema: Workstation.Core.Contracts.Recorded.positive_integer!(export, "schema", id),
          value: Map.get(export, "value")
        }
      end)

    :ok = Workstation.Core.Catalog.Spec.validate_exports(validated, id)
    validated
  end

  defp denormalize_exports(other, id),
    do: raise_arg("#{id}.exports must be a list, got: #{inspect(other)}")

  defp denormalize_context_requires(requires, id, declared) when is_list(requires) do
    validated =
      Enum.map(requires, fn req ->
        unless is_map(req), do: raise_arg("#{id}.context_requires entries must be objects")
        key = Workstation.Core.Contracts.Recorded.string!(req, "key", id)

        %{
          key: key,
          schema: Map.get(req, "schema"),
          in_requires: Enum.member?(declared, key)
        }
      end)

    :ok = Workstation.Core.Catalog.Spec.validate_context_requires(validated, id)
    Enum.map(validated, &Map.delete(&1, :in_requires))
  end

  defp denormalize_context_requires(other, id, _declared) when not is_list(other),
    do: raise_arg("#{id}.context_requires must be a list, got: #{inspect(other)}")

  defp require_string(map, field) do
    value = Map.get(map, field)
    nonempty_string?(value) || raise_arg("golden input #{field} must be a non-empty string")
    value
  end

  defp validate_string_list(values, label) when is_list(values) do
    Enum.with_index(values, 1)
    |> Enum.each(fn {value, index} ->
      nonempty_string?(value) || raise_arg("#{label}[#{index}] must be a non-empty string")
    end)
  end

  defp validate_string_list(_values, label), do: raise_arg("#{label} must be a list")

  defp nonempty_string?(value), do: is_binary(value) and value != ""

  defp raise_arg(message), do: raise(ArgumentError, message)
end
