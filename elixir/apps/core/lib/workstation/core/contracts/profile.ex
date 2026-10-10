defmodule Workstation.Core.Contracts.Profile do
  @moduledoc """
  The editor capability's profile contract: owns the profile-intent
  envelope — the field vocabulary language intents declare, its validators,
  and the intent-contribution constructor — the same ownership split as
  `Workstation.Core.Contracts.Shell` (fragment envelope) and
  `Workstation.Core.Contracts.Download` (pin).

  Layer: contract. The contract law: the kernel never names a capability's
  shape owner — intents address the provider id as data, and the envelope
  vocabulary lives here, discovered like every contract (implementor
  policy: the profile capability's compositor is whatever conforming
  `Workstation.Core.Contracts.Provider` module the package tree carries;
  this contract never names one.)

  Three-tier ownership: the ENGINE owns vocabulary and mechanics (effect
  kinds; the shape-driven normalization/ordering/duplicate machinery in
  `Workstation.Core.Platform.Profile`, parameterized by shape); this
  CAPABILITY contract owns the shape (which fields an intent declares and
  how each validates); PACKAGES own values (intents, cases, targets as
  pure data, addressed to the capability's provider id).
  """

  alias Workstation.Core.Platform.Profile

  # The canonical profile-intent envelope: the identity field is a required
  # non-empty string, the remaining string fields optional, the list fields
  # non-empty string lists, the case fields case-record lists with optional
  # string-keyed project_files.
  @shape %{
    string_fields: [:id, :plugin_module],
    list_fields: [:requires, :lazyvim_extras, :mason_packages],
    case_fields: %{language_cases: [:language, :filename, :contents, :client], formatter_cases: [:language, :filename, :contents, :expected]}
  }

  @type shape :: %{
          required(:string_fields) => [atom()],
          required(:list_fields) => [atom()],
          required(:case_fields) => %{optional(atom()) => [atom()]}
        }

  @doc "The profile-intent envelope: the shape language intents declare."
  @spec shape() :: Profile.shape()
  def shape, do: @shape

  @doc """
  One profile-intent contribution: normalize the declared raw intent to
  the canonical envelope, validate it, and wrap it as
  `%{provider: provider_id, spec: %{order:, entry:}}`. The caller names
  the profile capability's provider id as data (the same way recipe
  constructors name "chezmoi"), so the contract never names one.
  """
  @spec contribution(String.t(), pos_integer(), map()) :: %{provider: String.t(), spec: map()}
  def contribution(provider_id, order, raw) when is_binary(provider_id) do
    spec = %{order: order, entry: Profile.declared_entry(raw, @shape)}
    :ok = validate_intent_spec(spec, "profile intent")
    %{provider: provider_id, spec: spec}
  end

  @doc """
  Envelope validation for one profile-intent recipe: a positive integer
  order, an entry table, and the entry valid under the canonical shape.
  Label prefixes every rejection.
  """
  @spec validate_intent_spec(map(), String.t()) :: :ok
  def validate_intent_spec(spec, label) do
    validate_intent_spec(spec, @shape, label)
  end

  @doc "Validate one raw intent entry under the canonical shape."
  @spec validate_entry(term(), String.t()) :: map()
  def validate_entry(entry, label), do: Profile.validate_entry(entry, @shape, label)

  @doc """
  Envelope validation for one recorded/declared intent recipe: a positive
  integer order, an entry table, and the entry valid under the canonical
  shape. Label prefixes every rejection.
  """
  @spec validate_intent_spec(map(), shape(), String.t()) :: :ok
  def validate_intent_spec(spec, shape, label) when is_map(spec) do
    order = spec[:order]
    unless is_integer(order) and order > 0,
      do: raise_arg(label <> " recipe requires a positive integer order")
    unless is_map(spec[:entry]), do: raise_arg(label <> " recipe requires an entry table")
    validate_entry(spec[:entry], shape, label <> " entry " <> (spec[:entry][:id] |> to_string()))
    :ok
  end

  def validate_intent_spec(_spec, _shape, label),
    do: raise_arg(label <> " recipe must be a table")

  @doc """
  The composition ordering law (engine mechanics, delegated): entries
  sorted by the recipe's explicit order key with collection order as
  tie-break.
  """
  @spec order_intents([map()]) :: [map()]
  def order_intents(intents), do: Profile.order_intents(intents)

  @doc "Validate a composed profile (list, per-entry, duplicate-id rejection)."
  @spec validate_profile([map()], String.t()) :: [map()]
  def validate_profile(profile, label), do: validate_profile(profile, @shape, label)

  @doc "Validate a composed profile under an explicit shape (label-prefixed rejections)."
  @spec validate_profile([map()], shape(), String.t()) :: [map()]
  def validate_profile(profile, shape, label), do: Profile.validate_profile(profile, shape, label)

  @doc """
  Denormalize one recorded-envelope intent spec (string-keyed golden
  bytes) back to the declared atom shape. Label prefixes every rejection.
  """
  @spec recorded_spec(map(), shape(), String.t()) :: map()
  def recorded_spec(spec, shape, label), do: Profile.recorded_spec(spec, shape, label)

  @doc "Validate one raw intent entry under the canonical shape."
  @spec validate_entry(term(), shape(), String.t()) :: map()
  def validate_entry(entry, shape, label), do: Profile.validate_entry(entry, shape, label)

  defp raise_arg(message), do: raise(ArgumentError, message)
end
