defmodule Workstation.Core.Changesets do
  @moduledoc """
  Attributable change sets for every provisioning recipe. Byte-for-byte
  parity anchor: `workstation/lua/workstation/changesets.lua`.

  The Git-style patches describe GENERATED CHEZMOI SOURCE, never arbitrary
  HOME content: they are an inspectable review surface for apply/removal, not
  mutation authority and not a promise that backend effects are blindly
  reversible. Patches bind to a prior baseline that is verified against the
  journal's recorded manifest before anything is diffed — a stale or tampered
  generation fails closed instead of producing a diff against the wrong
  bytes.
  """

  alias Workstation.Core.EngineState
  alias Workstation.Core.Journal
  alias Workstation.Core.Provisioner

  @doc """
  Verified prior baseline: the journal's recorded manifest is rechecked
  against the stored generation directory (no-follow path, exact bytes) before
  any patch is derived from it. Returns nil when nothing was ever applied.
  """
  @spec verified_baseline() :: map() | nil
  def verified_baseline do
    state_root = EngineState.state_root()
    applied = Journal.applied(state_root)

    if is_map(applied) and applied["generation"] != nil do
      generation = applied["generation"]

      unless EngineState.valid_generation_id(generation) do
        raise(ArgumentError, "journal records an invalid generation identifier")
      end

      unless is_list(applied["manifest"]), do: raise(ArgumentError, "journal manifest is missing; rebuild the plan")

      unless is_map(applied["source_index"]), do: raise(ArgumentError, "journal source index is missing; rebuild the plan")

      directory = EngineState.generation_directory(state_root, generation)

      unless EngineState.lstat(directory),
        do: raise(ArgumentError, "recorded generation directory is missing: #{directory}")

      # verify_generation/2 raises with the exact offending entry on any
      # mismatch. A stale generation must never produce diffs.
      Provisioner.verify_generation(directory, applied["manifest"])

      %{
        "generation" => generation,
        "directory" => directory,
        "manifest" => applied["manifest"],
        "source_index" => applied["source_index"]
      }
    else
      nil
    end
  end

  defp octal(nil), do: nil
  defp octal(mode), do: Integer.to_string(mode, 8)

  @doc """
  Structured change-set records for one plan: active entries, then retired
  source entries that the plan no longer contains. A nil baseline resolves to
  the verified journal baseline.
  """
  @spec changesets(map(), map() | nil) :: [map()]
  def changesets(plan, baseline) do
    baseline = baseline || verified_baseline()

    records =
      Enum.map(plan["entries"], fn entry ->
        %{
          "owner" => entry["owner"],
          "attribution" => entry["attribution"],
          "provider" => entry["provider"],
          "operation" => entry["operation"],
          "target" => entry["target"],
          "source" => entry["source_name"],
          "type" => entry["type"],
          "mode" => octal(entry["mode"]),
          "link" => entry["link"],
          "shared" => if(entry["shared"], do: entry["shared"]),
          "source_fingerprint" => entry["fingerprint"]
        }
      end)

    if baseline do
      present = MapSet.new(plan["entries"], & &1["source_name"])

      retired =
        baseline["manifest"]
        |> Enum.filter(fn manifest_entry ->
          # Generated engine metadata is never a retired recipe: the
          # .chezmoiremove drift is previewed as the attributed aggregate
          # change below, and the data envelope simply stages with the
          # generation (parity anchor: changesets.lua:194). Without this
          # guard every journaled home reports both files as deletes —
          # invisible to fresh-journal sandboxes, caught on a real host.
          name = manifest_entry["name"]

          manifest_entry["type"] == "file" and not MapSet.member?(present, name) and
            name != ".chezmoiremove" and name != ".chezmoidata.toml"
        end)
        |> Enum.map(fn manifest_entry ->
          name = manifest_entry["name"]
          indexed = baseline["source_index"][name] || %{}

          %{
            "owner" => indexed["owner"] || "unknown",
            "attribution" => indexed["attribution"],
            "provider" => "chezmoi",
            "operation" => "retire",
            "target" => indexed["target"] || name,
            "source" => name,
            "type" => indexed["type"] || "file",
            "mode" => octal(indexed["mode"]),
            "link" => indexed["link"]
          }
        end)

      records ++ retired
    else
      records
    end
  end

  # Unified diff of generated source bytes in Git style. `previous` may be nil
  # (new source entry) or a path inside the verified baseline generation.
  # Labels — not temp paths — name both sides, so the emitted patch bytes are
  # deterministic regardless of staging.
  defp patch(name, previous, next_path) do
    {output, code} =
      System.cmd(
        "diff",
        ["-u", "--label", "a/" <> name, "--label", "b/" <> name, previous || "/dev/null", next_path || "/dev/null"],
        stderr_to_stdout: true
      )

    unless code in [0, 1], do: raise(ArgumentError, "diff failed: #{output}")
    if code == 0, do: "", else: output
  end

  defp sanitize_source_name(name), do: Regex.replace(~r/[^\w\-_.]/, name, "_")

  # Stage one entry's generated bytes for diffing; returns the temp path or
  # nil for non-text state. Each staged file is removed by the caller right
  # after its diff, so no patch staging ever outlives the call.
  defp stage_next(entry) do
    case entry["bytes"] do
      nil ->
        nil

      bytes ->
        base = Path.join(System.tmp_dir() || "/tmp", "workstation-patch-#{:os.getpid()}")
        path = base <> "-" <> sanitize_source_name(entry["source_name"])
        File.write!(path, bytes)
        path
    end
  end

  defp diff_entry(kind, entry, previous_path) do
    staged = stage_next(entry)
    diff = if staged, do: patch(entry["source_name"], previous_path, staged), else: ""
    if staged, do: File.rm(staged)

    if diff != "" or kind == "delete" do
      %{
        "kind" => kind,
        "source" => entry["source_name"],
        "owner" => entry["owner"],
        "attribution" => entry["attribution"],
        "target" => entry["target"],
        "type" => entry["type"],
        "mode" => octal(entry["mode"]),
        "link" => entry["link"],
        "diff" => if(diff != "", do: diff)
      }
    else
      nil
    end
  end

  defp metadata_record(kind, entry) do
    # Typed metadata only: directories carry mode, symlinks carry the link
    # destination; neither is honestly representable as text.
    %{
      "kind" => kind,
      "source" => entry["source_name"],
      "owner" => entry["owner"],
      "attribution" => entry["attribution"],
      "target" => entry["target"],
      "type" => entry["type"],
      "mode" => octal(entry["mode"]),
      "link" => entry["link"]
    }
  end

  @doc """
  Compute every generated-source patch for a plan: additions on first plans,
  changes against the verified baseline, and deletions for retired entries.
  Non-text state keeps typed metadata instead of a fabricated text inverse.
  The `.chezmoiremove` tombstone file is previewed as one attributed
  aggregate change naming the engine policy plus every removal's owner, never
  a fabricated single owner. A nil baseline resolves to the verified journal
  baseline.
  """
  @spec plan_patches(map(), map() | nil) :: [map()]
  def plan_patches(plan, baseline) do
    baseline = baseline || verified_baseline()

    entry_patches =
      Enum.flat_map(plan["entries"], fn entry ->
        previous_path = baseline && Path.join(baseline["directory"], entry["source_name"])

        previous_path =
          if baseline && EngineState.lstat(previous_path) == nil, do: nil, else: previous_path

        cond do
          entry["bytes"] == nil ->
            # is_nil/1 (not `not baseline`): Elixir's `not` is strict-boolean
            # and would raise on a map, where the anchor relies on Lua
            # truthiness (nil is falsy, a table is truthy).
            if is_nil(baseline) or baseline["source_index"][entry["source_name"]] == nil do
              [metadata_record("add", entry)]
            else
              []
            end

          baseline && baseline["source_index"][entry["source_name"]] != nil ->
            List.wrap(diff_entry("change", entry, previous_path))

          true ->
            List.wrap(diff_entry("add", entry, nil))
        end
      end)

    retire_patches =
      if baseline do
        present = MapSet.new(plan["entries"], & &1["source_name"])

        file_deletes =
          baseline["manifest"]
          |> Enum.filter(fn manifest_entry ->
            name = manifest_entry["name"]
            manifest_entry["type"] == "file" and not MapSet.member?(present, name)
          end)
          |> Enum.flat_map(fn manifest_entry ->
            name = manifest_entry["name"]

            if name == ".chezmoiremove" or name == ".chezmoidata.toml" do
              # Generated engine metadata: .chezmoiremove changes are
              # previewed as one attributed aggregate change below, and the
              # data envelope is never a retired recipe; neither is ever
              # reported as a deleted owned target.
              []
            else
              indexed = baseline["source_index"][name] || %{}
              diff = patch(name, Path.join(baseline["directory"], name), nil)

              [
                %{
                  "kind" => "delete",
                  "source" => name,
                  "owner" => indexed["owner"] || "unknown",
                  "attribution" => indexed["attribution"],
                  "target" => indexed["target"] || name,
                  "type" => indexed["type"] || "file",
                  "diff" => if(diff != "", do: diff)
                }
              ]
            end
          end)

        aggregate =
          aggregate_remove_patch(plan, baseline)

        file_deletes ++ List.wrap(aggregate)
      else
        []
      end

    entry_patches ++ retire_patches
  end

  # Aggregate tombstone changes name their contributors as the engine policy
  # plus every removal's owner, not a fabricated single owner.
  defp aggregate_remove_patch(plan, baseline) do
    previous_remove = safe_read(Path.join(baseline["directory"], ".chezmoiremove"))

    if previous_remove == plan["remove_file"] do
      nil
    else
      # The engine always sets a string tombstone body; a nil here means the
      # plan envelope is malformed, and staging must fail closed like the
      # anchor's write assertion instead of fabricating empty bytes.
      staged_content = plan["remove_file"]
      unless is_binary(staged_content), do: raise(ArgumentError, "plan remove_file must be a string")

      staged = Path.join(System.tmp_dir() || "/tmp", "workstation-remove-#{:os.getpid()}")
      File.write!(staged, staged_content)
      diff = patch(".chezmoiremove", Path.join(baseline["directory"], ".chezmoiremove"), staged)
      File.rm(staged)

      owners =
        Enum.uniq(["engine-policy" | Enum.map(plan["removals"] || [], & &1["owner"])])

      %{
        "kind" => "change",
        "source" => ".chezmoiremove",
        "owner" => "engine",
        "attribution" => owners,
        "target" => ".chezmoiremove (aggregate tombstones)",
        "type" => "file",
        "diff" => if(diff != "", do: diff)
      }
    end
  end

  defp safe_read(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, _reason} -> nil
    end
  end
end
