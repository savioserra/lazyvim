defmodule Workstation.Core.Source.Manifest do
  @moduledoc """
  Deterministic source manifest: every generated source path with type and
  mode, sorted by name so the generation id is stable.

  Every generated source path with type and mode, sorted by name so the
  generation id is stable. Engine source-root files (`.chezmoiremove`, the
  optional `.chezmoidata.toml`) are manifest entries without being plan
  targets: they stage with the generation and verify byte-for-byte, but never
  deploy into the home. Directories default to 0o755 and files to 0o644;
  only a declared private directory overrides that, because chezmoi's
  backend only distinguishes private from default for containers.
  """

  @default_directory_mode 0o755
  @default_file_mode 0o644

  @spec build([Workstation.Core.Source.entry()], [{String.t(), String.t()}]) :: [map()]
  def build(entries, pinned) when is_list(entries) and is_list(pinned) do
    {manifest, _seen} =
      Enum.reduce(entries, {[], MapSet.new()}, fn entry, {manifest, seen} ->
        # Directory entries carry no body; every other source entry type must
        # carry real bytes so a manifest digest is always computable.
        unless entry.type == "directory" or entry.bytes != nil do
          raise ArgumentError, "generated source file without bytes: #{entry.source_name}"
        end

        {manifest, seen} = include(entry_to_manifest(entry), manifest, seen)

        entry.source_name
        |> walk_prefixes()
        |> Enum.reduce({manifest, seen}, fn prefix, {manifest, seen} ->
          include(%{"name" => prefix, "type" => "directory", "mode" => @default_directory_mode}, manifest, seen)
        end)
      end)

    {manifest, _seen} =
      Enum.reduce(pinned, {manifest, seen_names(manifest)}, fn {name, bytes}, {manifest, seen} ->
        {manifest, seen} =
          include(
            %{"name" => name, "type" => "file", "mode" => @default_file_mode, "sha256" => Workstation.Core.Digest.sha256(bytes)},
            manifest,
            seen
          )

        # A pinned file nested below the source root (a download pin
        # descriptor) needs its parent directories declared exactly like a
        # generated source file's; existing flat pins have none.
        name
        |> walk_prefixes()
        |> Enum.reduce({manifest, seen}, fn prefix, {manifest, seen} ->
          include(%{"name" => prefix, "type" => "directory", "mode" => @default_directory_mode}, manifest, seen)
        end)
      end)

    Enum.each(manifest, fn entry ->
      unless entry["type"] != "file" or Map.has_key?(entry, "sha256") do
        raise ArgumentError, "manifest file entry has no digest: #{entry["name"]}"
      end
    end)

    Enum.sort_by(manifest, & &1["name"])
  end

  defp seen_names(manifest), do: MapSet.new(manifest, & &1["name"])

  defp include(entry, manifest, seen) do
    if MapSet.member?(seen, entry["name"]) do
      {manifest, seen}
    else
      {[entry | manifest], MapSet.put(seen, entry["name"])}
    end
  end

  # Manifest entries are string-keyed records; canonical encoding orders
  # every object by key (mode, name, sha256, type).
  defp entry_to_manifest(entry) do
    if entry.type == "directory" do
      %{"name" => entry.source_name, "type" => "directory", "mode" => entry.mode || @default_directory_mode}
    else
      # Symlink source files record the digest of their declared destination
      # string: the source path is a plain file
      # whose body is the link target, mode 0o644.
      %{
        "name" => entry.source_name,
        "type" => "file",
        "mode" => @default_file_mode,
        "sha256" => Workstation.Core.Digest.sha256(entry.bytes)
      }
    end
  end

  defp walk_prefixes(source_name) do
    case String.contains?(source_name, "/") do
      false ->
        []

      true ->
        prefix = source_name |> String.split("/") |> Enum.drop(-1) |> Enum.join("/")
        [prefix | walk_prefixes(prefix)]
    end
  end
end
