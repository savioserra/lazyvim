defmodule Workstation.Core.Source.Paths do
  @moduledoc """
  The path algebra shared by the source data shapes (entries / removals /
  shell / downloads): engine-private state targeting, ancestor containment
  and the fail-closed invalid-recipe raise. Pure — string algebra only, no
  filesystem, no I/O.

  Layer: kernel. The kernel law: this module is pure path algebra —
  containment, engine-private state and the one invalid-recipe raise — and
  it touches no package, no backend and no filesystem.
  """

  @engine_state_target ".local/state/workstation"

  @doc "The engine-private state target no recipe may ever touch."
  @spec engine_state_target() :: String.t()
  def engine_state_target, do: @engine_state_target

  @doc "True when `target` is `ancestor` itself or lives underneath it."
  @spec within?(String.t(), String.t()) :: boolean()
  def within?(target, ancestor),
    do: target == ancestor or String.starts_with?(target, ancestor <> "/")

  @doc "True when `ancestor` contains `target` (see `within?/2`)."
  @spec encompasses?(String.t(), String.t()) :: boolean()
  def encompasses?(ancestor, target), do: within?(target, ancestor)

  @doc "Fail closed when a recipe target overlaps engine-private state."
  @spec assert_not_engine_state!(String.t()) :: :ok
  def assert_not_engine_state!(target) do
    not within?(target, @engine_state_target) ||
      invalid!("recipe target overlaps engine-private state: #{target}")

    :ok
  end

  @doc "The one invalid-recipe raise: every shape fails closed with a sentence."
  @spec invalid!(String.t()) :: no_return()
  def invalid!(message), do: raise(ArgumentError, message)
end
