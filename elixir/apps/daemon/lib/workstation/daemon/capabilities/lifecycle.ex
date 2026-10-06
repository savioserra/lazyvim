defmodule Workstation.Daemon.Capabilities.Lifecycle do
  @moduledoc """
  Wire surface of the lifecycle verbs: `bootstrap.run`, `sync.run`,
  `verify.run`, `pull.run`, plus the `update.run` op — since the streaming
  refactor a FULL CHAIN op (`"steps"`, canonical-order subsequence), with
  the single-step (`"step"`) spelling kept as the chain-of-one primitive.

  Every lifecycle op runs through `Workstation.Daemon.Lifecycle.run_chain/3`
  under its op's `op_ref`, so progress streams to the client while the
  daemon owns the chain — the client renders events, it never drives steps.
  The abort contract (`op.abort`) is honoured at step boundaries, which only
  exist between chain steps — another reason the chain is daemon-side.

  Params are otherwise empty: the daemon serves its own pinned home, and the
  engine checkout resolves from the daemon's own environment
  (`WORKSTATION_ENGINE_REPO`, else the checkout walk) exactly like the
  one-shot era. The op bodies live in `Workstation.Daemon.Lifecycle`, which
  preserves the one-shot lock purposes, error codes, and the release
  handoff note contract (docs/capabilities.md) — a refreshed bootstrap
  writes the note and the daemon stops itself so every later op runs from
  the refreshed release.
  """

  @behaviour Workstation.Daemon.Capability

  alias Workstation.Daemon.{Capability, Lifecycle, Shutdown}

  # Same list as Workstation.Core.Update.steps/0 — the compile-time mirror
  # is pinned by a daemon test so the wire enum cannot drift from the core.
  @steps Lifecycle.canonical_steps()

  # The chain steps whose SUCCESSFUL run can refresh the release and
  # therefore stale this daemon (the refreshed? flag from the chain fold).
  @refresh_steps ["bootstrap"]

  @empty_schema Zoi.object(%{}, unrecognized_keys: :error)

  @step_enum Zoi.enum(@steps)

  @update_schema Zoi.object(
                   %{
                     "step" => Zoi.optional(@step_enum),
                     "steps" => Zoi.optional(Zoi.array(@step_enum))
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
  def handle("update.run", %{"steps" => steps}, ctx) do
    case Lifecycle.valid_chain?(steps) do
      {:ok, steps} -> run_chain(steps, ctx)
      {:error, message} -> {:error, {"invalid_params", message}}
    end
  end

  # The chain-of-one primitive: one named step, identical semantics and
  # events as the same step inside a chain. Exactly one spelling per
  # request: both (or neither) is a params violation.
  def handle("update.run", %{"step" => _step, "steps" => _steps}, _ctx),
    do: {:error, {"invalid_params", "update.run takes exactly one of step or steps"}}

  def handle("update.run", %{"step" => step}, ctx), do: run_chain([step], ctx)

  def handle("update.run", %{}, _ctx),
    do: {:error, {"invalid_params", "update.run takes exactly one of step or steps"}}

  def handle(op, _params, ctx), do: run_chain([verb_name(op)], ctx)

  # Params are empty by schema (the daemon serves its pinned home); the wire
  # result is the record, and the refresh stop decision rides the chain's
  # refreshed? flag — a bootstrap ANYWHERE in the chain that refreshed the
  # release stales this daemon.
  defp run_chain(steps, ctx) do
    case Lifecycle.run_chain(steps, Capability.op_ref(ctx), Capability.opts(ctx)) do
      {:ok, record, refreshed?} ->
        if refreshed? and Enum.any?(steps, &(&1 in @refresh_steps)) do
          :ok = Shutdown.stop_after("release refresh handoff")
          {:ok, record}
        else
          {:ok, record}
        end

      {:handoff, record, remaining} ->
        # A mid-chain refresh halted the chain: the daemon is stale the
        # moment this reply flushes. The result carries the handoff marker
        # plus the steps that did NOT run, so the client re-spawns from the
        # refreshed release and resumes exactly those (same lock, same
        # chain numbering — docs/capabilities.md "release refresh and
        # handoff").
        :ok = Shutdown.stop_after("release refresh handoff")
        {:ok, Map.merge(record, %{"handed_off" => true, "remaining_steps" => remaining})}

      {:error, code, message} ->
        {:error, {code, message}}
    end
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
  # (The stop fires from run_chain/2 above, which owns the refreshed? flag.)

  @impl true
  def domains, do: []

  @impl true
  def children, do: []
end
