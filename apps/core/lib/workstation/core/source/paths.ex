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

  # The hot-dir ruling (t_8b80ce3b, 2026-10-15): `.hermes` is the Hermes
  # agent's live home — the agent mutates it between applies, so ANY
  # backend state derived under it (source entries, ancestor directories,
  # recorded mtimes) fights those writes and fails every apply on an
  # agent-active host. Mutable agent state is served by the copy contract;
  # only a zero-source-entries-under-`.hermes` design converges.
  @hermes_home ".hermes"

  @doc "The agent home no backend source entry may ever derive from."
  @spec hermes_home() :: String.t()
  def hermes_home, do: @hermes_home

  @doc """
  Fail closed when a BACKEND recipe target would derive source state under
  the hot home (`.hermes` — the ruling: a directory a running program
  mutates between applies is never source-tracked). Explicit removals are
  exempt before this guard: they carry no source name and no ancestors, so
  a tombstone inside the hot home dir-tracks nothing.
  """
  @spec assert_not_hermes_home!(String.t()) :: :ok
  def assert_not_hermes_home!(target) do
    within?(target, @hermes_home) &&
      invalid!(
        "recipe target is under the hot home #{@hermes_home}: #{target} — hot state is never " <>
          "source-tracked; serve mutable payloads through the copy contract instead"
      )

    :ok
  end

  @doc "The one invalid-recipe raise: every shape fails closed with a sentence."
  @spec invalid!(String.t()) :: no_return()
  def invalid!(message), do: raise(ArgumentError, message)
end
