defmodule Workstation.Daemon.Capabilities.System do
  @moduledoc """
  Layer: kernel. The kernel law: this module names no package, no backend
  and no workspace — it relays the substrate's generation receipts on the
  wire, and the `system` domain name is its only knowledge.

  The `system` overlay domain: nix generation switches, heard live.

  On the nix substrate the WRITE PLANE is nix's own (`home-manager switch`
  / `nixos-rebuild switch` — the `workstation-switch` drivers the nix
  modules stage). Every successful switch publishes one event on this
  domain so both readers can subscribe:

    * the daemon hears it over the EXISTING wire protocol — the switch
      driver's publish step calls `workstation system applied`, which
      serves `system.applied` here; the op fans the event out on the
      `{:domain, "system"}` event-bus topic (`Workstation.Daemon.Overlay.pub/2`)
      and returns the record as the op result, so a headless driver has a
      synchronous receipt, and
    * the evaluator reads the publish CONTRACT (domain name, op name,
      event shape) from the walker's eval report — byte-guarded by
      `tests/nix/goldens/eval-report.json` in check.sh's eval-goldens
      gate, and cross-checked against THIS module's constants by
      `Workstation.Daemon.Capabilities.SystemTest` so the two readers
      cannot drift silently.

  The event speaks the nix profile generation ("generation N applied
  (rollback available at N-1)"), NOT the engine release generation —
  that rendezvous identity is `Workstation.Daemon.Generation` and stays
  a different axis.

  This module owns the domain name but does not CLAIM it (same posture as
  the theme capability): publishing is best-effort fanout; a second
  switch while a follower holds the domain must never `{:error, :taken}`.
  """

  use Workstation.Daemon.Capability

  require Logger

  alias Workstation.Daemon.Overlay

  @domain "system"
  @op "system.applied"

  # The switch driver publishes the applied generation plus the rollback
  # generation it saw before the switch (absent on a first-ever switch —
  # nothing to roll back to). Strict: unknown keys fail closed like every
  # other op's params.
  @applied_params_schema Zoi.object(
                           %{
                             "generation" => Zoi.integer(gte: 1),
                             "rollback_generation" => Zoi.optional(Zoi.integer(gte: 1))
                           },
                           unrecognized_keys: :error
                         )

  @impl true
  def ops, do: [@op]

  @impl true
  def schema(@op), do: @applied_params_schema

  @impl true
  def domains, do: [@domain]

  @impl true
  def handle(@op, params, _ctx) do
    generation = params["generation"]
    rollback = Map.get(params, "rollback_generation")
    event = {:system_applied, applied_event(generation, rollback)}

    Overlay.pub(@domain, event)

    # The receipt lives in the daemon's own journal too: a headless switch
    # driver has the op result, and a host audit (the VM E2E greps it via
    # `journalctl --user -u workstation-daemon`) has this line. Identifiers
    # only — the params never log (see `Workstation.Daemon.Events`).
    Logger.info("system domain: #{event |> elem(1) |> Map.fetch!("message")}")

    {:ok, event |> elem(1)}
  end

  @doc "The domain name this capability owns (the eval-report contract)."
  @spec domain() :: String.t()
  def domain, do: @domain

  @doc "The wire op name (the eval-report contract)."
  @spec op() :: String.t()
  def op, do: @op

  @doc """
  The event map for one applied generation — the op result AND the shape
  fanned out on the `{:domain, "system"}` topic (as `{:system_applied, map}`).

  The operator-facing line is the contract the card pins: "generation N
  applied (rollback available at M)" — M is the generation the switch
  replaced; a first-ever switch has no prior generation and says so.
  """
  @spec applied_event(pos_integer(), pos_integer() | nil) :: map()
  def applied_event(generation, rollback) when is_integer(generation) and generation >= 1 do
    %{
      "type" => "system.applied",
      "domain" => @domain,
      "generation" => generation,
      "rollback_generation" => rollback,
      "message" => message(generation, rollback)
    }
  end

  defp message(generation, nil),
    do: "generation #{generation} applied (no prior generation)"

  defp message(generation, rollback) when is_integer(rollback) and rollback >= 1,
    do: "generation #{generation} applied (rollback available at #{rollback})"
end
