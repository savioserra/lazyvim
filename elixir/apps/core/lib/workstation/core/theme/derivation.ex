defmodule Workstation.Core.Theme.Derivation do
  @moduledoc """
  Layer: kernel. The kernel law: this module names no consumer — derivation
  needs and rendering adapters are declared by the caller; the platform
  speaks only roles, appearances and resolved palettes.

  The theme derivation contract: a package declares what it needs from the
  token set (which roles, which appearances), and derives its artifact
  through a consumer-owned rendering adapter. The platform validates the
  declaration against the token set fail-closed (an unknown role or
  appearance refuses the derivation instead of guessing), resolves the
  palette, and hands it to the adapter — the consumer owns rendering; the
  platform owns resolution and the law.

  The canon — the three derivation patterns engine consumers use, in the
  order docs/theme.md formalizes them:

    * *Envelope-rendered* — the package requires the theme capability and
      its payloads are templates rendered against the data envelope
      (`Workstation.Core.Theme.Tokens.data_envelope/0`); no per-build
      adapter runs, the backend renders. For consumers that emit whole
      files from role data.
    * *Terminal-following* — no generated artifact at all: the consumer's
      own live config follows the host terminal's palette, and the
      derivation declaration records that choice so the theme contract
      carries no consumer record. For consumers that must never be
      regenerated behind their own live state.
    * *Upstream-truthed* — the consumer rides an upstream palette and the
      engine's token values mirror it for engine-side surfaces; the
      declaration documents the alignment and no runtime derivation runs.
      For consumers whose color truth lives upstream.

  The resolved-palette consumer (in-process surfaces that overlay roles at
  runtime) is not a derivation: it resolves through
  `Workstation.Core.Theme.resolve/1` against the same token set, so there
  is exactly one color truth per layer.
  """

  alias Workstation.Core.Theme

  @type needs :: %{String.t() => term()}
  @type descriptor :: %{String.t() => term()}
  @type adapter :: (resolved_palette() -> binary())
  @type resolved_palette :: %{required(String.t()) => String.t()}

  @doc """
  Declare one package's derivation needs: `"roles"` (subset of the token
  role set, string-keyed) and `"appearances"` (subset of the accepted
  appearances). Returns the validated descriptor; raises `ArgumentError`
  on an unknown role or appearance, an empty role set, or a malformed
  declaration — a derivation that names nothing, or names what does not
  exist, is refused rather than silently served.
  """
  @spec declare(needs()) :: descriptor()
  def declare(%{"roles" => roles, "appearances" => appearances} = needs)
      when is_list(roles) and is_list(appearances) do
    :ok = validate_roles(roles)
    :ok = validate_appearances(appearances)
    extra = Map.drop(needs, ["roles", "appearances"])
    Map.merge(%{"roles" => Enum.sort(roles), "appearances" => Enum.sort(appearances)}, extra)
  end

  def declare(%{"roles" => _, "appearances" => _}),
    do: raise_arg("theme derivation needs: roles and appearances must be lists")

  def declare(_other), do: raise_arg("theme derivation needs require \"roles\" and \"appearances\"")

  @doc """
  Derive one artifact from the declared needs through the consumer-owned
  adapter: for each declared appearance the base palette (role -> hex) is
  resolved from the token set and handed to the 1-arity renderer, whose
  binary output is returned paired with the appearance. The adapter owns
  rendering — the platform owns resolution, ordering (declared appearance
  order) and the binary contract.
  """
  @spec derive(descriptor(), adapter()) :: [{String.t(), binary()}]
  def derive(%{"roles" => _roles, "appearances" => appearances} = _descriptor, renderer)
      when is_function(renderer, 1) do
    Enum.map(appearances, fn appearance ->
      {:ok, resolved} = Theme.resolve(%{"appearance" => appearance})
      artifact = renderer.(resolved)

      unless is_binary(artifact),
        do: raise_arg("theme derivation adapter must render a binary")

      {appearance, artifact}
    end)
  end

  def derive(_descriptor, _renderer), do: raise_arg("theme derivation requires a 1-arity adapter")

  @doc "Roles a derivation may declare (the full palette surface)."
  @spec known_roles() :: [String.t()]
  def known_roles, do: Theme.settable_roles()

  # --- private: fail-closed declaration checks ---

  defp validate_roles([]), do: raise_arg("theme derivation needs at least one role")

  defp validate_roles(roles) do
    known = MapSet.new(known_roles())

    Enum.each(roles, fn role ->
      unless is_binary(role) and MapSet.member?(known, role),
        do: raise_arg("theme derivation: unknown role #{inspect(role)}")
    end)

    :ok
  end

  defp validate_appearances([]), do: raise_arg("theme derivation needs at least one appearance")

  defp validate_appearances(appearances) do
    known = MapSet.new(Theme.appearances())

    Enum.each(appearances, fn appearance ->
      unless is_binary(appearance) and MapSet.member?(known, appearance),
        do: raise_arg("theme derivation: unknown appearance #{inspect(appearance)}")
    end)

    :ok
  end

  defp raise_arg(message), do: raise(ArgumentError, message)
end
