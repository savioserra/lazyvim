defmodule Workstation.Core.Source.Removals do
  @moduledoc """
  The removal data shape of the source assembler: one declared removal
  literal, validated fail-closed. Engine-private state is never touched,
  active ownership is never overlapped, and the backend interprets
  .chezmoiremove entries as glob patterns, so one literal owned target must
  not be able to expand into several removals.

  Layer: kernel. The kernel law: a declared removal is a literal relative
  path — no control bytes, no glob metacharacters, no engine-private state.
  """

  alias Workstation.Core.Source.Paths

  @doc "Validate one final removal literal."
  @spec validate_literal!(String.t()) :: :ok
  def validate_literal!(target) do
    is_binary(target) and target != "" || Paths.invalid!("invalid removal entry")

    not String.match?(target, ~r/[\x00-\x1f\x7f]/) ||
      Paths.invalid!("removal entry must not contain control characters or newlines: #{target}")

    not String.match?(target, ~r/[*?\[\]]/) ||
      Paths.invalid!("removal entry contains glob metacharacters the backend would expand: #{target}")

    not String.starts_with?(target, "/") && not Regex.match?(~r/\.\.($|\/)/, target) ||
      Paths.invalid!("removal entry must be a literal relative path")

    not Paths.within?(target, Paths.engine_state_target()) &&
        not Paths.encompasses?(target, Paths.engine_state_target()) ||
      Paths.invalid!("removal entry would touch engine-private state: #{target}")

    :ok
  end
end
