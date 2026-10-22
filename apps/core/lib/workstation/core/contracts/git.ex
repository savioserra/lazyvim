defmodule Workstation.Core.Contracts.Git do
  @moduledoc """
  The pinned-clone recipe kind: a git checkout pinned to an exact commit
  (url + commit + target), provisioned by declared recipe — never placed by
  hand.

  Layer: contract. The contract law: the kernel names no pin source —
  pinned clones are engine vocabulary published through discovery, and
  packages declare pins as data against the kind, never as recipe code
  (implementor policy: this engine module is the pinned-clone kind's only
  implementor).

  An engine-owned recipe kind — mechanism vocabulary, like file/symlink — that carries its own declared
  effects. The composition handshake lives here
  (`Workstation.Core.Contracts.Provider`): the catalog
  discovers `provider: "git"` contributions through it, golden replay
  denormalizes recorded pins through it, and composition returns the pin
  inventory as the provider's composed domain view — the plan's capability
  profile entries the declared-program fold derives clone effects from. The
  declared-program handshake (`Workstation.Core.Contracts.Contract`) lives in the
  sibling `Workstation.Core.Contracts.Git.Effects`: one module per behaviour, so
  the two handshakes never fight over callbacks and both discoveries stay
  behaviour-conformance checks.

  Fail-closed posture, matching the pinned-download contract: https urls
  only, the commit must be a 40-hex lowercase sha, the target is a relative
  literal path that never touches engine-private state, and one checkout
  target may have only one owner.
  """

  @behaviour Workstation.Core.Contracts.Provider

  alias Workstation.Core.{CanonicalJSON, Digest}

  @commit_format ~r/\A[0-9a-f]{40}\z/
  @engine_state_target ".local/state/workstation"

  @doc "The wire provider id for pinned-clone contributions."
  @impl Workstation.Core.Contracts.Provider
  @spec id() :: String.t()
  def id, do: "git"

  @doc """
  Build one validated pin from its declared fields. Raises `ArgumentError`
  on any invalid field: the url must be https (the supply-chain posture of a
  pinned checkout), the commit a 40-hex lowercase sha, and the target a safe
  relative literal path that never touches engine-private state.
  """
  @spec recipe(map()) :: map()
  def recipe(attrs) when is_map(attrs) do
    url = field(attrs, :url)
    commit = field(attrs, :commit)
    target = field(attrs, :target)

    validate_url(url)
    validate_commit(commit)
    validate_target(target)

    %{id: id(), url: url, commit: commit, target: target, fingerprint: pin_fingerprint(url, commit, target)}
  end

  @doc "The pin fingerprint: content address over the exact pin fields."
  @spec pin_fingerprint(String.t(), String.t(), String.t()) :: String.t()
  def pin_fingerprint(url, commit, target) do
    Digest.sha256(CanonicalJSON.encode(%{"commit" => commit, "target" => target, "url" => url}))
  end

  @doc """
  Validate one declared pin spec: exactly the three pin fields (a composed
  recipe may additionally carry its derived id/fingerprint). Raises
  `ArgumentError` on the first invalid field.
  """
  @impl Workstation.Core.Contracts.Provider
  @spec validate_spec(map()) :: :ok
  def validate_spec(spec) when is_map(spec) do
    url = field(spec, :url)
    commit = field(spec, :commit)
    target = field(spec, :target)

    validate_url(url)
    validate_commit(commit)
    validate_target(target)

    unknown = Map.keys(spec) -- [:url, :commit, :target, :id, :fingerprint]
    unknown == [] || raise(ArgumentError, "git recipe has unknown fields: #{inspect(unknown)}")

    :ok
  end

  def validate_spec(other), do: raise(ArgumentError, "git recipe must be a map, got: #{inspect(other)}")

  @doc """
  Denormalize one recorded-envelope spec (string-keyed golden bytes) back to
  the validated atom-keyed recipe, so replay compares equal to native
  declarations.
  """
  @impl Workstation.Core.Contracts.Provider
  @spec denormalize_spec(map()) :: map()
  def denormalize_spec(spec) when is_map(spec) do
    recipe(%{
      url: Map.get(spec, "url"),
      commit: Map.get(spec, "commit"),
      target: Map.get(spec, "target")
    })
  end

  def denormalize_spec(other),
    do: raise(ArgumentError, "git recipe must be a table, got: #{inspect(other)}")

  @doc """
  Compose the collected pins (graph-ordered `%{owner:, spec:}` records) into
  the provider's plan contribution: the source record (spliced back into
  the collection under the git provider id) and the composed domain view —
  the pin inventory the effect contract derives its clone effects from. One
  target may have only one owner; duplicate targets conflict instead of
  racing.
  """
  @impl Workstation.Core.Contracts.Provider
  @spec compose([%{required(:owner) => String.t(), required(:spec) => map()}]) :: {map(), [map()]}
  def compose(intents) when is_list(intents) do
    intents != [] || raise(ArgumentError, "git composition requires at least one intent")

    {pins, _seen} =
      Enum.map_reduce(intents, MapSet.new(), fn intent, seen ->
        :ok = validate_spec(intent.spec)
        pin = recipe(intent.spec) |> Map.put(:owner, intent.owner)
        MapSet.member?(seen, pin.target) &&
          raise(ArgumentError, "duplicate git target #{pin.target}: one checkout target may have only one owner")

        {pin, MapSet.put(seen, pin.target)}
      end)

    record = %{owner: "git", provider: id(), spec: pins, attribution: Enum.map(pins, & &1.owner)}
    {record, Enum.map(pins, &Map.put(&1, :git_pin, true))}
  end

  defp field(attrs, key) do
    value = Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
    is_binary(value) and value != "" || raise(ArgumentError, "git recipe requires #{key}")
    value
  end

  defp validate_url(url) do
    String.starts_with?(url, "https://") ||
      raise(ArgumentError, "git url must be https (pinned supply chain), got: #{url}")
  end

  defp validate_commit(commit) do
    Regex.match?(@commit_format, commit) ||
      raise(ArgumentError, "git commit must be a 40-hex lowercase sha, got: #{commit}")
  end

  defp validate_target(target) do
    not String.match?(target, ~r/[\x00-\x1f\x7f]/) ||
      raise(ArgumentError, "git target must not contain control characters: #{target}")

    not String.match?(target, ~r/[*?\[\]]/) ||
      raise(ArgumentError, "git target must be a literal path: #{target}")

    not String.starts_with?(target, "/") && not String.starts_with?(target, "~") &&
        not Regex.match?(~r/(\A|\/)\.\.?(\z|\/)/, target) ||
      raise(ArgumentError, "git target must be a relative path inside the home: #{target}")

    not is_within(target, @engine_state_target) && not encompasses(target, @engine_state_target) ||
      raise(ArgumentError, "git target overlaps engine-private state: #{target}")

    :ok
  end

  defp is_within(target, ancestor), do: target == ancestor or String.starts_with?(target, ancestor <> "/")
  defp encompasses(ancestor, target), do: is_within(target, ancestor)
end

defmodule Workstation.Core.Contracts.Git.Effects do
  @moduledoc """
  The pinned-clone effect contract: the declared-program handshake of the
  git recipe kind (`Workstation.Core.Contracts.Contract`, discovered by
  behaviour conformance — the fold never names it).

  Layer: contract. The contract law: the fold never names a mutation —
  every clone effect derives from the plan's composed pin inventory through
  the discovered contract (implementor policy: this engine module is the
  pinned-clone kind's only declared-program implementor).

  One clone effect per composed pin, derived from the plan's capability
  profile (the provider's pin inventory). Purely declarative: the effect
  names the pinned checkout the program carries — execution retired with
  the engine's write plane (the nix substrate's workstation-switch drivers
  own the clone).
  """

  @behaviour Workstation.Core.Contracts.Contract

  @doc "The wire contract id of pinned-clone effects (matches the provider id)."
  @impl Workstation.Core.Contracts.Contract
  @spec id() :: String.t()
  def id, do: "git"

  @doc "Validate one declared pin spec (the behaviour's spec entry point)."
  @impl Workstation.Core.Contracts.Contract
  @spec validate_spec(map()) :: :ok
  def validate_spec(spec), do: Workstation.Core.Contracts.Git.validate_spec(spec)

  @doc """
  The plan's clone effects: one typed effect per composed pin (derived from
  the provider's domain view carried by the plan — the capability profile
  entries marked `git_pin`). Per-target phase — every clone runs before the
  staged-generation apply effect.
  """
  @impl Workstation.Core.Contracts.Contract
  @spec plan_effect(term(), map()) :: [map()]
  def plan_effect(plan, _ctx) do
    clone_effects =
      plan.profile
      |> List.wrap()
      |> Enum.filter(&Map.get(&1, :git_pin))
      |> Enum.map(fn pin ->
        %{
          contract: id(),
          kind: :clone,
          phase: :target,
          owner: pin.owner,
          target: pin.target,
          url: pin.url,
          commit: pin.commit,
          fingerprint: pin.fingerprint
        }
      end)

    clone_effects
  end

end
