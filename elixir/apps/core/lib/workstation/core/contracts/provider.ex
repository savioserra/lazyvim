defmodule Workstation.Core.Contracts.Provider do
  @moduledoc """
  The capability-provider contract of the source assembler.

  Domain-generic machinery (chezmoi, shell, chezmoi-data) is wired directly
  into `Workstation.Core.Source`; a CAPABILITY-specific provider (a package
  that composes its own contribution shape) implements this behaviour from
  its own package module namespace instead. The engine source never names a
  capability provider: provider ids are discovered from the implementing
  modules (`Workstation.Core.Contracts.Provider.Discover`), and composition
  dispatches through this contract, so a new capability provider plugs in
  with zero edits to the assembler.

  Dependency direction: the consumer package -> this contract, never the
  assembler -> the consumer. `ArchitectureDepsTest` locks that direction.
  """

  @doc "The wire provider id this implementation owns (e.g. a capability's declared intent provider)."
  @callback id() :: String.t()

  @doc """
  Validate one raw recipe spec (atom-keyed, as declared by its owning
  package module). Raises `ArgumentError` on invalid shape.
  """
  @callback validate_spec(map()) :: :ok

  @doc """
  Compose the collected intents (graph-ordered `%{owner: id, spec: recipe}`
  records contributed under this provider id) into the provider's output:
  `{source_record, profile}` where `source_record` is the provider-owned
  entry record (owner, provider, spec, attribution) it contributes to the
  plan and `profile` is its composed domain view (`[]` when the provider
  publishes none).
  """
  @callback compose([%{required(:owner) => String.t(), required(:spec) => map()}]) ::
              {map(), [map()]}

  @doc """
  Denormalize one recorded-envelope spec (string-keyed, as recorded by the
  golden oracle) back to the atom-keyed declared shape, so replay compares
  equal to native declarations. Raises `ArgumentError` on invalid shape.
  """
  @callback denormalize_spec(map()) :: map()
end

defmodule Workstation.Core.Contracts.Provider.Discover do
  @moduledoc """
  Runtime capability-provider discovery, mirroring
  `Workstation.Core.Catalog.Discover`: the assembler's capability surface is
  whatever conforming `Workstation.Core.Contracts.Provider` modules the code
  path carries under the package namespace — never a hand-written registry.

  Candidates come from `:code.all_available/0` narrowed to the
  `Workstation.Packages.*` namespace (capability providers are
  owned by their package module), test-tree beams are excluded by recorded
  source path, and conformance requires the behaviour attribute plus the
  full callback set. The pipeline itself is the shared
  `Workstation.Core.Contracts.Discovery` helper — this module supplies
  only the capability-provider parameterization. The namespace is shared
  with package-spec discovery and with effect-contract discovery;
  conformance is per declared behaviour — a package-owned recipe kind may
  carry both handshakes (composition and effects) in one module.
  (implementor policy: a capability provider is whatever conforming
  `Workstation.Core.Contracts.Provider` module the package namespace
  carries — the assembler never names one.)
  """

  @callbacks [id: 0, validate_spec: 1, compose: 1, denormalize_spec: 1]

  @doc """
  The discovered capability-provider modules, sorted by module name —
  declaration order is not a thing.
  """
  @spec providers() :: [module()]
  def providers do
    Workstation.Core.Contracts.Discovery.modules(%{
      namespace: "Elixir.Workstation.Packages.",
      behaviour: Workstation.Core.Contracts.Provider,
      callbacks: @callbacks,
      label: "source-provider"
    })
  end

  @doc "Provider id -> implementing module, from the discovered set."
  @spec by_id() :: %{String.t() => module()}
  def by_id do
    Map.new(providers(), fn module -> {module.id(), module} end)
  end

  @doc "Look up the implementing module for one provider id."
  @spec lookup(String.t()) :: {:ok, module()} | :error
  def lookup(id) when is_binary(id) do
    case Map.fetch(by_id(), id) do
      {:ok, module} -> {:ok, module}
      :error -> :error
    end
  end

  def lookup(_other), do: :error
end
