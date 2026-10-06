defmodule Workstation.Daemon.Capabilities.Lifecycle do
  @moduledoc """
  Wire surface of the lifecycle verbs: `bootstrap.run`, `sync.run`,
  `verify.run`, `pull.run`, plus the per-step `update.run` the client
  chains.

  Params are empty: the daemon serves its own pinned home, and the engine
  checkout resolves from the daemon's own environment
  (`WORKSTATION_ENGINE_REPO`, else the checkout walk) exactly like the
  one-shot era. The op bodies live in `Workstation.Daemon.Lifecycle`, which
  preserves the one-shot lock purposes, error codes, and the release
  handoff note contract (docs/capabilities.md) — a refreshed bootstrap
  writes the note and the daemon stops itself so every later op runs from
  the refreshed release.
  """

  @behaviour Workstation.Daemon.Capability

  alias Workstation.Daemon.{Lifecycle, Shutdown}

  # Same list as Workstation.Core.Update.steps/0 — the compile-time mirror
  # is pinned by a daemon test so the wire enum cannot drift from the core.
  @steps ["pull", "bootstrap", "apply", "sync", "verify"]

  # The surfaces whose SUCCESSFUL bootstrap can refresh the release and
  # therefore stale this daemon (see stop_after_refresh/1).
  @refresh_ops ["bootstrap.run"]
  @refresh_steps ["bootstrap"]

  @empty_schema Zoi.object(%{}, unrecognized_keys: :error)

  @update_schema Zoi.object(
                   %{
                     "step" => Zoi.enum(@steps)
                   },
                   unrecognized_keys: :error
                 )

  @impl true
  def ops, do: ["bootstrap.run", "pull.run", "sync.run", "update.run", "verify.run"]

  @impl true
  def schema("bootstrap.run"), do: @empty_schema
  def schema("sync.run"), do: @empty_schema
  def schema("verify.run"), do: @empty_schema
  def schema("pull.run"), do: @empty_schema
  def schema("update.run"), do: @update_schema

  @impl true
  def handle("update.run", %{"step" => step}, _ctx) do
    result = Lifecycle.run_step(step)
    maybe_stop_after_refresh(step, @refresh_steps, result)
  end

  def handle(op, _params, _ctx) do
    result = Lifecycle.verb(verb_name(op))
    maybe_stop_after_refresh(op, @refresh_ops, result)
  end

  defp verb_name("bootstrap.run"), do: "bootstrap"
  defp verb_name("sync.run"), do: "sync"
  defp verb_name("verify.run"), do: "verify"
  defp verb_name("pull.run"), do: "pull"

  # A bootstrap whose release refresh SUCCEEDED just made this daemon
  # stale: the on-disk release changed under the running code, and every
  # later op must come from the refreshed code. The daemon therefore stops
  # itself after the reply flushes (Workstation.Daemon.Shutdown); the
  # client's ensure-daemon re-spawns from the refreshed release, and the
  # handoff note left by the step routes the remaining chain there. The
  # stop lives at the WIRE layer — in-process callers (tests, composition
  # harnesses) run the same Lifecycle without terminating their VM.
  defp maybe_stop_after_refresh(surface, refresh_surfaces, result)
       when is_binary(surface) and is_list(refresh_surfaces) do
    with true <- surface in refresh_surfaces,
         {:ok, %{"release_refreshed" => true} = record} <- result do
      :ok = Shutdown.stop_after("release refresh handoff")
      {:ok, record}
    else
      _other -> wire_result(result)
    end
  end

  # Lifecycle failures are `{:error, code, message}` — the operator-facing
  # vocabulary (`locked` under contention, otherwise the step code) carried
  # verbatim on the wire so the client's exit-code contract is unchanged.
  defp wire_result({:ok, record}), do: {:ok, record}
  defp wire_result({:error, code, message}), do: {:error, {code, message}}

  @impl true
  def domains, do: []

  @impl true
  def children, do: []
end
