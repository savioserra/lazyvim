defmodule Workstation.Core.Source.Downloads do
  @moduledoc """
  The download data shape of the source assembler: pinned-artifact
  contributions become validated download records, and a download target
  owns its path exclusively — any overlap with an owned entry or a declared
  removal is a composition conflict. Pure — the fetch itself never happens
  at plan time.

  Layer: kernel. The kernel law: a pinned artifact owns its target
  exclusively — any overlap with an owned entry or a declared removal fails
  the composition before the plan exists.
  """

  alias Workstation.Core.Contracts.Download
  alias Workstation.Core.Source.Paths

  # Pinned artifacts are validated at composition: every record is a
  # validated recipe and the plan carries the derived fingerprint and the
  # staged descriptor name.
  @spec compose([map()]) :: [map()]
  def compose(collected) do
    collected
    |> Enum.filter(&(&1.provider == Download.provider_id()))
    |> Enum.map(fn record ->
      spec = record.spec
      :ok = Download.validate(spec)

      %{
        owner: record.owner,
        target: spec.target,
        url: spec.url,
        version: spec.version,
        sha256: spec.sha256,
        fingerprint: Download.fingerprint(spec),
        source_name: Download.pin_source_name(spec)
      }
    end)
    |> Enum.reduce({[], MapSet.new()}, fn download, {downloads, seen} ->
      if MapSet.member?(seen, download.target) do
        Paths.invalid!("duplicate download target #{download.target}: one artifact target may have only one owner")
      end

      {downloads ++ [download], MapSet.put(seen, download.target)}
    end)
    |> elem(0)
  end

  # Downloaded artifacts own their targets exclusively: a chezmoi entry or
  # a declared removal reaching the same path is a composition conflict,
  # checked before the plan exists so replay fails loudly.
  @spec check_conflicts([map()], [map()], [map()]) :: :ok
  def check_conflicts(downloads, entries, removals) do
    Enum.each(downloads, fn download ->
      Enum.each(entries, fn entry ->
        overlapping =
          download.target == entry.target or Paths.encompasses?(download.target, entry.target) or
            Paths.encompasses?(entry.target, download.target)

        overlapping &&
          Paths.invalid!(
            "download target #{download.target} overlaps owned target #{entry.target} " <>
              "(#{Enum.join(entry.attribution, ",")})"
          )
      end)

      Enum.each(removals, fn removal ->
        not Paths.encompasses?(removal.target, download.target) ||
          Paths.invalid!("declared removal #{removal.target} overlaps download target #{download.target}")
      end)
    end)
  end
end
