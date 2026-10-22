defmodule Workstation.Core.Contracts.Copy do
  @moduledoc """
  The copied-payload contract: a package declares a payload file copied
  into the home by byte-compare copy — no backend source state is ever
  derived from it.

  Layer: contract. The contract law: a copy declares exactly its declared
  asset bytes at exactly its declared target — nothing else is ever
  declared (implementor policy: implementations are the engine's own
  contract modules; discovery finds them by behaviour conformance).

  The contract exists for HOT state: directories a running program mutates
  between applies (the Hermes agent home) must never carry backend source
  entries, because any tracked state there fights the program's writes and
  fails every apply on an agent-active host (the 2026-10-15 hot-dir ruling:
  "stop dir tracking"). A copy carries no source name, no ancestors and no
  directory modes — the plan derives nothing from it but one target-phase
  effect.

  The plan stays pure: a copy recipe contributes a validated spec whose
  ASSET REFERENCE travels (declared manifest, recorded envelope, plan,
  effect) — the reference stays a reference through every read face; the
  catalog's one auditable asset seam (`Workstation.Core.Catalog.package_asset!/2`)
  is where bytes resolve. The declared-field
  fingerprint (the `Workstation.Core.Source.Entries` fingerprint pattern,
  bytes dropped) is content-addressed, so two recipes differing in any
  declared field never share a source fingerprint. Execution retired with
  the engine's write plane (the nix substrate's workstation-switch drivers
  own the copy).
  """

  @behaviour Workstation.Core.Contracts.Contract

  alias Workstation.Core.{CanonicalJSON, Digest}

  @enforce_keys [:asset, :target]
  defstruct [:asset, :target, :executable]

  @type t :: %__MODULE__{
          asset: String.t(),
          target: String.t(),
          executable: boolean() | nil
        }

  @doc "The wire provider id for copied-payload contributions."
  @spec provider_id() :: String.t()
  def provider_id, do: "copy"

  @doc "The wire contract id of copy effects (matches the provider id)."
  @impl Workstation.Core.Contracts.Contract
  @spec id() :: String.t()
  def id, do: provider_id()

  @doc """
  Build one validated copy recipe. Raises `ArgumentError` on any invalid
  field: the asset must be a safe package-relative path, the target a safe
  home-relative path that never touches engine-private state, and
  `executable` (optional) a boolean — a true flag serves the payload at
  0755 instead of 0644.
  """
  @spec recipe(map()) :: t()
  def recipe(attrs) when is_map(attrs) do
    asset = fetch_field(attrs, :asset)
    target = fetch_field(attrs, :target)
    validate_asset(asset)
    validate_target(target)

    executable = Map.get(attrs, :executable) || Map.get(attrs, "executable")

    unless executable == nil or is_boolean(executable) do
      raise(ArgumentError, "copy executable must be boolean, got: #{inspect(executable)}")
    end

    %__MODULE__{asset: asset, target: target, executable: executable}
  end

  @doc "Validate one declared spec (the behaviour's spec entry point)."
  @impl Workstation.Core.Contracts.Contract
  @spec validate_spec(term()) :: :ok
  def validate_spec(%__MODULE__{} = spec) do
    validate_asset(spec.asset)
    validate_target(spec.target)

    unless spec.executable == nil or is_boolean(spec.executable) do
      raise(ArgumentError, "copy executable must be boolean, got: #{inspect(spec.executable)}")
    end

    :ok
  end

  def validate_spec(other),
    do: raise(ArgumentError, "copy recipe must be a validated struct, got: #{inspect(other)}")

  @doc """
  Denormalize one recorded-envelope spec (string-keyed golden bytes, or a
  declared data manifest under the `declared` bracket) back to the validated
  recipe struct, so replay compares equal to native declarations. The asset
  stays a package-relative REFERENCE in both brackets — the copy contract
  never inlines bytes, so a recorded plan is machine-independent and the
  owning package always supplies the bytes. Raises
  `ArgumentError` on an invalid shape.
  """
  @impl Workstation.Core.Contracts.Contract
  @spec from_recorded(map(), map()) :: t()
  def from_recorded(spec, ctx) when is_map(spec) do
    unless Map.keys(spec) -- ["asset", "target", "executable"] == [] do
      raise(ArgumentError, "copy recipe has unknown fields: #{inspect(Map.keys(spec) -- ["asset", "target", "executable"])}")
    end

    recipe(%{
      asset: Map.get(spec, "asset"),
      target: Map.get(spec, "target"),
      executable: Map.get(spec, "executable")
    })
  rescue
    e in [ArgumentError] ->
      raise ArgumentError, "invalid copy recipe for #{ctx.package_id}: #{Exception.message(e)}"
  end

  def from_recorded(other, _ctx),
    do: raise(ArgumentError, "copy recipe must be a table, got: #{inspect(other)}")

  # --- the effect contract ---

  # One typed effect per declared copy, all phase :target: payload serving
  # happens BEFORE the staged generation applies (like every per-target
  # effect), and a refused serve must never leave a half-applied generation
  # behind — the pending record, which carries the copy targets, is the
  # recovery anchor.
  @impl Workstation.Core.Contracts.Contract
  @spec plan_effect(term(), map()) :: [map()]
  def plan_effect(plan, _ctx) do
    case Map.get(plan, :copies) || [] do
      [] ->
        []

      copies ->
        Enum.map(copies, fn copy ->
          %{
            contract: id(),
            kind: :copy,
            phase: :target,
            owner: copy.owner,
            target: copy.target,
            asset: copy.asset,
            executable: copy.executable,
            fingerprint: copy.fingerprint
          }
        end)
    end
  end

  @doc """
  The declared fingerprint: content address over the exact declared fields
  (the entries.ex fingerprint pattern, asset bytes dropped — the reference
  travels, bytes resolve at apply). Two recipes differing in any declared
  field never share a source fingerprint.
  """
  @spec fingerprint(t() | map()) :: String.t()
  def fingerprint(spec) do
    fields =
      %{"asset" => field(spec, :asset), "target" => field(spec, :target)}
      |> maybe_put("executable", field(spec, :executable))

    Digest.sha256(CanonicalJSON.encode(fields))
  end

  defp validate_asset(asset) do
    outside? =
      String.starts_with?(asset, "/") or String.starts_with?(asset, "~") or
        Regex.match?(~r/(^|\/)\.\.(\/|$)/, asset) or String.match?(asset, ~r/[\x00-\x1f\x7f\\]/)

    outside? &&
      raise(ArgumentError, "copy asset must be a relative package path inside its package: #{asset}")

    :ok
  end

  defp validate_target(target) do
    not String.match?(target, ~r/[\x00-\x1f\x7f]/) ||
      raise(ArgumentError, "copy target must not contain control characters: #{target}")

    not String.match?(target, ~r/[*?\[\]]/) ||
      raise(ArgumentError, "copy target must be a literal path: #{target}")

    not String.starts_with?(target, "/") and not String.starts_with?(target, "~") and
        not Regex.match?(~r/(\A|\/)\.\.?(\/|\z)/, target) ||
      raise(ArgumentError, "copy target must be a relative path inside the home: #{target}")

    within_engine_state? =
      target == engine_state_target() or String.starts_with?(target, engine_state_target() <> "/") or
        String.starts_with?(engine_state_target(), target <> "/")

    not within_engine_state? ||
      raise(ArgumentError, "copy target overlaps engine-private state: #{target}")

    :ok
  end

  defp engine_state_target, do: ".local/state/workstation"

  defp fetch_field(attrs, key) do
    value = Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
    is_binary(value) and value != "" || raise(ArgumentError, "copy recipe requires #{key}")
    value
  end

  defp field(spec, key) when is_map(spec), do: Map.get(spec, key)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
