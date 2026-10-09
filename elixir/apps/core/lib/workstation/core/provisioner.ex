defmodule Workstation.Core.Provisioner do
  @moduledoc """
  The chezmoi provisioner — generation verification, argv contract and the
  staged-generation writer. Parity anchors:
  `workstation/lua/workstation/provisioner.lua` (`verify_generation`, `argv`,
  `write_staged`, `publish`).

  Chezmoi is a subordinate file provisioner invoked with an explicit
  immutable generated `--source` generation directory and `--destination`
  home; it is never driven by the user or by packages, and home effects are
  never patched directly. Every generation is content-addressed by the SHA-256
  of its manifest, staged into a private directory, verified byte-for-byte and
  only then renamed into place — so an interrupted publish can never leave a
  half-written generation under its content address. A generation directory
  that already exists is re-verified, and a damaged one is quarantined under
  an `.invalid-*` name, never deleted in place, because its bytes are the only
  evidence of what an earlier run published.
  """

  alias Workstation.Core.EngineState

  @doc """
  Verify a generation directory byte-for-byte against its manifest: every
  entry present with the exact type, permission bits and content digest, and
  nothing else. A hash-shaped pathname alone is never trusted. Manifest
  structure errors (missing names/digests, duplicates) raise before any
  filesystem read, mirroring the Lua assertions.
  """
  @spec verify_generation(String.t(), [map()]) :: true
  def verify_generation(root, manifest) when is_binary(root) and is_list(manifest) do
    expected =
      Enum.reduce(manifest, %{}, fn entry, acc ->
        name = entry["name"]
        unless is_binary(name) and name != "", do: raise(ArgumentError, "manifest entry has no name")

        unless entry["type"] != "file" or is_binary(entry["sha256"]),
          do: raise(ArgumentError, "manifest file entry has no digest: #{name}")

        unless not Map.has_key?(acc, name), do: raise(ArgumentError, "duplicate manifest entry: #{name}")

        Map.put(acc, name, entry)
      end)

    actual = walk(root, "")

    Enum.each(expected, fn {name, entry} ->
      # Bracket access (not fetch!/2): the anchor's own missing-entry message
      # must fire for a manifest entry with no on-disk counterpart.
      record = actual[name]

      unless record, do: raise(ArgumentError, "generation is missing entry: #{name}")
      unless record["type"] == entry["type"], do: raise(ArgumentError, "generation entry has the wrong type: #{name}")
      unless record["mode"] == entry["mode"], do: raise(ArgumentError, "generation entry has the wrong mode: #{name}")

      unless is_nil(entry["sha256"]) or record["sha256"] == entry["sha256"],
        do: raise(ArgumentError, "generation entry has the wrong bytes: #{name}")
    end)

    map_size(actual) == map_size(expected) ||
      raise(ArgumentError, "generation contains unexpected entries")

    true
  end

  defp walk(root, prefix) do
    root
    |> File.ls!()
    |> Enum.reduce(%{}, fn child, acc ->
      name = if prefix == "", do: child, else: prefix <> "/" <> child
      path = Path.join(root, child)

      case EngineState.lstat(path) do
        nil -> raise(ArgumentError, "generation entry is missing: #{name}")
        %{type: "file", mode: mode} -> Map.put(acc, name, %{"type" => "file", "mode" => mode, "sha256" => EngineState.sha256(File.read!(path))})
        %{type: "directory", mode: mode} -> Map.merge(Map.put(acc, name, %{"type" => "directory", "mode" => mode}), walk(path, name))
        %{type: type, mode: mode} -> Map.put(acc, name, %{"type" => type, "mode" => mode})
      end
    end)
  end

  @doc """
  Build the full chezmoi argv for an action against one exact immutable
  generation directory, never a mutable current pointer. `opts` carries the
  string keys `"source"` (required generation path), `"destination"` (defaults
  to the target home), `"dry_run"` and `"exclude"` (defaults to `["scripts"]`,
  because engine-owned lifecycle scripts must never run inside a preview).
  """
  @spec argv(String.t(), map()) :: [String.t()]
  def argv(action, opts) when is_binary(action) and is_map(opts) do
    source = opts["source"]
    unless is_binary(source) and source != "", do: raise(ArgumentError, "chezmoi argv requires an explicit source generation")

    destination = opts["destination"] || EngineState.home()

    prefix = [
      chezmoi_executable(),
      "--source",
      source,
      "--destination",
      destination,
      action
    ]

    prefix =
      if opts["dry_run"] do
        prefix ++ ["--dry-run"]
      else
        prefix
      end

    Enum.reduce(opts["exclude"] || ["scripts"], prefix, fn exclude, acc ->
      acc ++ ["--exclude", exclude]
    end)
  end

  defp chezmoi_executable do
    Path.join([EngineState.home(), ".local", "opt", "chezmoi", "bin", "chezmoi"])
  end

  # The staged tree's permission bits are exactly the manifest's: the
  # generation id binds to those bits, so the writer never invents a fallback
  # mode. Manifest directories default to 0o755 and files to 0o644 for
  # mode-less entries (see `Workstation.Core.Source.Manifest`), the same
  # defaults the anchor derives from `entry.mode || 493` / `entry.mode || 420`.
  @staging_prefix ".staging-"
  @staging_attempts 64

  @doc """
  Materialize one plan's generation directory under
  `<state_root>/generations/<generation>`: the staged bytes are the pinned
  engine source-root files (`.chezmoiremove`, and the optional
  `.chezmoidata.toml` from the plan's data envelope) plus every entry's
  `source_name` body, written in manifest order with the manifest's exact type
  and mode. The tree is built under a private `.staging-*` directory and
  renamed into place only after `verify_generation/2` walks it byte-for-byte.

  Re-publishing an existing, intact generation is a no-op; a damaged one is
  renamed to `<generation>.invalid-<pid>-<time>` — quarantine, never deletion —
  and freshly staged. `opts` carries `"home"` (defaults to the target home)
  for the guarded state-chain anchor; every write hangs off
  `Workstation.Core.EngineState.ensure_tree!/4`.
  """
  @spec publish(Workstation.Core.Source.t(), map()) :: String.t()
  def publish(%Workstation.Core.Source{} = plan, opts \\ %{}) do
    home = opts["home"] || EngineState.home()
    state_root = Path.join([home | EngineState.state_components()])

    unless EngineState.valid_generation_id(plan.generation),
      do: raise(ArgumentError, "plan has an invalid generation identifier")

    # The generations root is private engine state, not a cache: it is created
    # (or repaired) through the same guarded chain as the journal.
    :ok = EngineState.ensure_tree!(home, EngineState.state_components() ++ ["generations"], "generations root")
    generations_root = Path.join(state_root, "generations")
    directory = Path.join(generations_root, plan.generation)

    case EngineState.lstat(directory) do
      nil ->
        stage(generations_root, directory, plan)

      %{type: "directory"} ->
        # An intact generation is never restaged: its content address already
        # names exactly these bytes, and the anchor returns early (provisioner
        #.lua publish: verify, then return). Only a quarantined tree stages
        # afresh.
        case verify_existing(directory, plan) do
          :ok -> :ok
          :quarantined -> stage(generations_root, directory, plan)
        end

      _other ->
        raise ArgumentError, "recorded generation is not a directory: #{directory}"
    end

    directory
  end

  # An existing generation directory is re-verified, never trusted. A damaged
  # one is quarantined and re-staged from the current plan; deleting in place
  # would destroy the only record of what a previous run published under this
  # content address.
  defp verify_existing(directory, plan) do
    true = verify_generation(directory, plan.manifest)
    :ok
  rescue
    ArgumentError ->
      quarantine = "#{directory}.invalid-#{:os.getpid()}-#{System.system_time(:second)}"
      File.rename!(directory, quarantine)
      :quarantined
  end

  defp stage(generations_root, directory, plan) do
    staged = staged_bytes(plan)
    staging_root = staging_root(generations_root)

    try do
      Enum.each(plan.manifest, fn entry ->
        write_staged(staging_root, entry, staged)
      end)

      verify_generation(staging_root, plan.manifest)
      File.rename!(staging_root, directory)
    rescue
      # A failed publish leaves no partial tree behind: the staging name is
      # disposable, the generation address never becomes one.
      error ->
        File.rm_rf!(staging_root)
        reraise error, __STACKTRACE__
    end
  end

  # The pinned engine source-root files first (they are manifest entries
  # without being plan targets), then one body per generated source name. A
  # manifest file entry without staged bytes raises before anything is
  # written: a half-mapped generation must never exist on disk.
  defp staged_bytes(plan) do
    bodies =
      plan.entries
      |> Enum.flat_map(fn entry ->
        if entry.bytes, do: [{entry.source_name, entry.bytes}], else: []
      end)
      |> Map.new()

    bodies
    |> maybe_pin(".chezmoiremove", plan.remove_file)
    |> maybe_pin(".chezmoidata.toml", plan.data && plan.data.bytes)
    |> Map.merge(download_pins(plan))
  end

  # Each download pin stages its descriptor: the generation directory carries
  # the machine-readable provenance of every pinned artifact, verified
  # byte-for-byte with the generation like any other staged file.
  defp download_pins(plan) do
    Map.new(plan.downloads, fn download ->
      {download.source_name, Workstation.Core.Source.Download.pin_bytes(download)}
    end)
  end

  defp maybe_pin(map, _name, nil), do: map
  defp maybe_pin(map, name, bytes), do: Map.put(map, name, bytes)

  defp write_staged(staging_root, entry, staged) do
    path = Path.join(staging_root, entry["name"])
    :ok = ensure_prefixes(staging_root, entry["name"])

    case entry["type"] do
      "directory" ->
        File.mkdir!(path)
        File.chmod!(path, entry["mode"])

      "file" ->
        # Bracket access with an explicit guard, not fetch!/2: a missing body
        # is a plan-integrity failure and must name the source entry.
        bytes = staged[entry["name"]]

        unless is_binary(bytes),
          do: raise(ArgumentError, "generated source file without staged bytes: #{entry["name"]}")

        File.write!(path, bytes)
        File.chmod!(path, entry["mode"])

      other ->
        raise ArgumentError, "manifest entry has unsupported type #{inspect(other)}: #{entry["name"]}"
    end
  end

  # Ancestors are (re)created at 0755 exactly like the anchor's prefix loop;
  # idempotent because manifest prefix entries may already have made them.
  defp ensure_prefixes(root, name) do
    name
    |> String.split("/")
    |> Enum.drop(-1)
    |> Enum.reduce(root, fn part, current ->
      next = Path.join(current, part)

      case EngineState.lstat(next) do
        nil ->
          File.mkdir!(next)
          File.chmod!(next, 0o755)

        %{type: "directory"} ->
          :ok

        _other ->
          raise ArgumentError, "generation path is not a directory: #{next}"
      end

      next
    end)

    :ok
  end
  # Exclusive private staging name: the pid/unique-integer tuple makes
  # collisions theoretical, and the bounded retry keeps a pathological one a
  # loud failure instead of a silent clobber.
  defp staging_root(generations_root) do
    Enum.reduce_while(1..@staging_attempts, nil, fn _attempt, acc ->
      path = Path.join(generations_root, "#{@staging_prefix}#{:os.getpid()}-#{System.unique_integer([:positive])}")

      case File.mkdir(path) do
        :ok ->
          # Pin the private mode: the published generation directory inherits
          # this mode at rename, so it must not depend on the process umask.
          File.chmod!(path, 0o700)
          {:halt, path}
        {:error, :eexist} -> {:cont, acc}
        {:error, reason} -> raise ArgumentError, "cannot create staging directory: #{inspect(reason)}"
      end
    end)
    |> case do
      nil -> raise ArgumentError, "staging directory creation did not converge"
      path -> path
    end
  end
end
