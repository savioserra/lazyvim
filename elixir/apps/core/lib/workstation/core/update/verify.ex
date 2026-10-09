defmodule Workstation.Core.Update.Verify do
  @moduledoc """
  The `verify` step of the update lifecycle: the engine-owned verify
  surface — assert the public launcher is still canonical and every applied
  target still matches the fingerprint the journal recorded when it claimed
  ownership, reported per owning package.

  Parity anchor: the Lua verify verb (`workstation/apps/cli/run.lua`:
  `launcher.verify(root)` then the per-package runner). The Elixir engine's
  "packages" are the journal's owning packages, and the observable behavior
  is per owning contract: file-shaped records verify against the recorded
  fingerprint (type + mode + content digest / link value), and records an
  effect contract claims (the optional `verify_record/2` seam,
  contract-discovered — a pinned checkout re-checks HEAD against its pin)
  verify through their own contract. The journal is the ownership anchor,
  and verify must cover every effect kind the pipeline can produce. A
  failed verification means the home diverged from the engine's own
  provenance — a failed verify, never silently accepted.
  """

  alias Workstation.Core.Contracts.Contract
  alias Workstation.Core.{EngineState, Journal}

  # The fingerprint fields the journal compares (the provenance record adds
  # owner/operation/source provenance on top; those are identity, not state).
  @fingerprint_fields ["type", "mode", "sha256", "link"]

  @doc """
  Verify. Returns `{:ok, %{"step" => "verify", "status" => "ok",
  "generation" => generation, "packages" => [package records]}}` with one
  deterministic record per owning package; raises `ArgumentError` when
  nothing was ever applied, the launcher is not canonical, or any target
  drifted from its recorded fingerprint.
  """
  @spec run(keyword()) :: {:ok, map()}
  def run(opts \\ []) when is_list(opts) do
    root = Workstation.Core.Update.engine_root(opts)
    home = Keyword.get(opts, :home) || EngineState.home()
    state_root = Path.join([home | EngineState.state_components()])

    applied = Journal.applied(state_root)

    unless applied,
      do: raise(ArgumentError, "verify: no applied generation; run apply first")

    verify_launcher!(root, home)

    packages = verify_targets!(applied, home)
    drifted = Enum.filter(packages, &(&1["status"] == "drifted"))

    unless drifted == [] do
      details = Enum.map_join(drifted, "; ", &"#{&1["package"]}: #{Enum.join(&1["drifted"], ", ")}")

      raise ArgumentError, "verify: targets drifted from the applied generation #{applied["generation"]}: #{details}"
    end

    {:ok,
     %{
       "step" => "verify",
       "status" => "ok",
       "generation" => applied["generation"],
       "packages" => packages
     }}
  end

  # launcher.lua verify: the launcher must be THE canonical matching symlink.
  defp verify_launcher!(root, home) do
    target = Workstation.Core.Update.realpath(Path.join(root, "bin/workstation"))
    launcher = Path.join([home, ".local", "bin", "workstation"])

    canonical? =
      case File.read_link(launcher) do
        {:ok, ^target} -> true
        _other -> false
      end

    unless canonical?,
      do:
        raise(
          ArgumentError,
          "verify: public launcher mismatch; inspect the path and run bootstrap: #{launcher}"
        )
  end

  # The verify seam: a record an effect contract claims (first discovered
  # :ok wins; :unclaimed passes to the next) verifies through that
  # contract's own re-check — its recorded fingerprint fields are the live
  # truth it just verified. Records no contract claims fall through to the
  # default file-fingerprint verification. A claimed-but-failed record
  # raises from the contract (a failed verify, never silently accepted).
  defp live_fingerprint(record, home, target) do
    if contract_claimed?(record, %{"home" => home, "target" => target}) do
      Map.take(record, @fingerprint_fields)
    else
      EngineState.target_fingerprint(home, target)
    end
  end

  defp contract_claimed?(record, ctx) do
    Contract.Discover.contracts()
    |> Enum.find_value(fn contract ->
      if function_exported?(contract, :verify_record, 2) do
        case contract.verify_record(record, ctx) do
          :ok -> true
          :unclaimed -> nil
        end
      end
    end)
    |> case do
      true -> true
      _other -> false
    end
  end

  defp verify_targets!(applied, home) do
    applied["targets"]
    |> Enum.map(fn {target, record} ->
      {Map.get(record, "owner", "unknown"), target, Map.take(record, @fingerprint_fields),
       live_fingerprint(record, home, target)}
    end)
    |> Enum.group_by(fn {owner, _target, _recorded, _live} -> owner end, fn {_owner, target, recorded, live} ->
      {target, recorded, live}
    end)
    |> Enum.map(fn {owner, entries} ->
      entries = Enum.sort_by(entries, &elem(&1, 0))

      drifted =
        for {target, recorded, live} <- entries,
            live != recorded,
            do: target

      %{
        "package" => owner,
        "targets" => length(entries),
        "status" => if(drifted == [], do: "ok", else: "drifted"),
        "drifted" => drifted
      }
    end)
    |> Enum.sort_by(& &1["package"])
  end
end
