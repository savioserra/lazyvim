defmodule Workstation.Daemon.Read do
  @moduledoc """
  The daemon-side read engine: `status` and `plan` evaluation behind the
  wire ops `status.run` and `plan.run`.

  This is the single source of the read-side wire assembly (moved here from
  the CLI in the engine client/server refactor): the CLI daemon client
  routes every read verb through the daemon and renders the returned wire
  unchanged, so the daemon is the one place that composes the declared
  surface. The declared-state source is the BAKED REPORT
  (`Workstation.Core.Report` — `flake.evalReport` baked into this release
  by `nix/engine.nix`); there is no other. The daemon always serves its own
  pinned home (the home it booted with); ops carry no home parameter.

  The wires (schema `workstation.status.v2` / `workstation.plan.v2`):

    * status — the engine block, the resolved destination, the platform,
      the report's counts, capability order and per-capability accounting
      (the declared inventory).
    * plan — the report digest as the generation id, the declared surface
      (file targets, tree claims, the retire list, the fragment lane), and
      the per-target live states (lstat no-follow, `absent` / `link -> dest`
      / `type mode-octal`). The declared-vs-live review surface is the
      engine's honest contribution; ownership and baseline remain the nix
      generation diff (`nix store diff-closures` / `home-manager
      generations`). The plan never mutates.

  State-root bracketing: the core reads engine state through
  `Workstation.Core.EngineState.home/0` (`WORKSTATION_HOME`). This module
  brackets that variable around evaluation and restores the previous value,
  so an evaluation always sees exactly the selected home and never the
  ambient environment. The bracket is process-global and brief.
  """

  alias Workstation.Core.{EngineState, Report}

  @engine_name "workstation"

  @status_schema "workstation.status.v2"
  @plan_schema "workstation.plan.v2"

  @doc "Schema identifier of the hard-cut status wire."
  def status_schema, do: @status_schema

  @doc "Schema identifier of the hard-cut plan wire."
  def plan_schema, do: @plan_schema

  @type error :: {:error, {:core, String.t()}} | {:error, {:engine, String.t()}}

  @doc """
  Evaluate one read command for `home`. Returns `{:ok, wire}` with the
  hard-cut schema for the command, or an error tagged `{:engine, reason}`
  (a missing or malformed baked report — the client's engine exit; there is
  no declared state to serve without the report).
  """
  @spec evaluate(atom(), String.t(), keyword()) :: {:ok, map()} | error()
  def evaluate(command, home, opts) when command in [:status, :plan] and is_list(opts) do
    expanded = Path.expand(home)

    report =
      try do
        {:ok, Report.decoded()}
      rescue
        error in [ArgumentError] -> {:error, {:engine, Exception.message(error)}}
      end

    case report do
      {:ok, report} ->
        bracket(expanded, fn ->
          case command do
            :status -> {:ok, status(expanded, report)}
            :plan -> {:ok, plan(expanded, report)}
          end
        end)

      error ->
        error
    end
  end

  @doc """
  Build the status wire: the declared inventory — counts, the capability
  order and the per-capability accounting rows, report-verbatim.
  """
  def status(destination, report) do
    %{
      "schema" => @status_schema,
      "engine" => %{"name" => @engine_name, "version" => engine_version(), "mode" => "report"},
      "destination" => destination,
      "platform" => Report.platform(),
      "counts" => report["counts"],
      "capabilityOrder" => report["capabilityOrder"],
      "capabilities" => report["accounting"]
    }
  end

  @doc """
  Build the plan wire: the declared surface (file targets, tree claims, the
  retire tombstones, the fragment lane) plus the probed live state of every
  declared target — the plan itself never probes (replay purity is dead with
  the replay; the probe is the read's contribution), so the daemon owns the
  lstat and reports the actual pre-switch state.
  """
  def plan(destination, report) do
    declared = %{
      "fileTargets" => report["fileTargetNames"],
      "claimTargets" => report["claimTargets"],
      "retire" => retire(report),
      "fragmentOrder" => report["fragmentOrder"]
    }

    targets = declared["fileTargets"] ++ declared["claimTargets"] ++ declared["retire"]

    states =
      Map.new(targets, fn target ->
        {target, describe_target_state(EngineState.join_home(destination, target))}
      end)

    %{
      "schema" => @plan_schema,
      "generation" => Report.digest(),
      "declared" => declared,
      "target_states" => states
    }
  end

  # The declared tombstones: every capability's retire list, in capability
  # order (the rows are disjoint — one owner per tombstone).
  defp retire(report) do
    order = report["capabilityOrder"]
    by_id = Map.new(report["accounting"], fn row -> {row["id"], row} end)

    Enum.flat_map(order, fn id ->
      case Map.fetch(by_id, id) do
        {:ok, row} -> row["retire"]
        :error -> []
      end
    end)
  end

  ## state-root bracket

  defp bracket(home, fun) do
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    try do
      fun.()
    rescue
      error -> {:error, {:core, Exception.message(error)}}
    after
      restore_state_root(previous)
    end
  end

  defp restore_state_root(nil), do: System.delete_env("WORKSTATION_HOME")
  defp restore_state_root(previous), do: System.put_env("WORKSTATION_HOME", previous)

  defp describe_target_state(path) do
    case EngineState.lstat(path) do
      nil ->
        "absent"

      # EngineState.lstat names symlinks "link" (read_link_info, never
      # dereferenced); the destination still resolves for the review line.
      %{type: type} when type in ["link", "symlink"] ->
        case :file.read_link(path) do
          {:ok, dest} -> "link -> " <> to_string(dest)
          {:error, _reason} -> "link"
        end

      %{type: type, mode: mode} ->
        "#{type} #{Integer.to_string(mode, 8)}"
    end
  end

  # The engine version is the release's CLI application version; outside a
  # release (dev/test) the placeholder keeps the schema total.
  defp engine_version, do: to_string(Application.spec(:cli, :vsn) || "0.0.0")
end
