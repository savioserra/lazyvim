defmodule Workstation.Core.Update.Verify do
  @moduledoc """
  The `verify` step of the update lifecycle: the engine-owned verify
  surface — assert the public launcher is still canonical and every applied
  target still matches the fingerprint the journal recorded when it claimed
  ownership, reported per owning package.

  Parity anchor: the Lua verify verb (`workstation/apps/cli/run.lua`:
  `launcher.verify(root)` then the per-package runner). The Elixir engine's
  "packages" are the journal's owning packages, and the observable behavior
  it can honestly assert is file-level: the recorded fingerprint
  (type + mode + content digest / link value) must still match the live
  target, because that fingerprint is the ownership claim every later
  precondition trusts. A drifted target means the home diverged from the
  engine's own provenance — a failed verify, never silently accepted.
  """

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

  defp verify_targets!(applied, home) do
    applied["targets"]
    |> Enum.map(fn {target, record} ->
      {Map.get(record, "owner", "unknown"), target, Map.take(record, @fingerprint_fields),
       EngineState.target_fingerprint(home, target)}
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
