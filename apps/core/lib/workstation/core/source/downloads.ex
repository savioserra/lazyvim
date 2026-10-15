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

      # The declared shape travels verbatim: a dispatched pin carries its
      # assets and its per-platform targets unresolved (the apply boundary
      # resolves through the contract), and the archive form's fields ride
      # the same way (nil on every file pin).
      base = %{owner: record.owner, target: spec.target, targets: spec.targets, version: spec.version}

      pin =
        case spec.assets do
          nil ->
            Map.merge(base, %{
              url: spec.url,
              sha256: spec.sha256,
              assets: nil,
              archive: spec.archive,
              layout: spec.layout,
              probe: spec.probe
            })

          assets ->
            base
            |> Map.put(:assets, assets)
            |> Map.put(:archive, spec.archive)
            |> Map.put(:layout, spec.layout)
            |> Map.put(:probe, spec.probe)
        end

      pin
      |> Map.merge(%{fingerprint: Download.fingerprint(spec), source_name: Download.pin_source_name(spec)})
    end)
    |> Enum.reduce({[], MapSet.new()}, fn download, {downloads, seen} ->
      key = ownership_key(download)

      if MapSet.member?(seen, key) do
        Paths.invalid!("duplicate download target #{download.target || Enum.join(declared_targets(download), ", ")}: one artifact target may have only one owner")
      end

      {downloads ++ [download], MapSet.put(seen, key)}
    end)
    |> elem(0)
  end

  # The exclusive-ownership key: the literal target, or the sorted declared
  # per-platform targets for a dispatched pin.
  defp ownership_key(download) do
    case download.target do
      nil -> {:targets, declared_targets(download)}
      target -> {:target, target}
    end
  end

  defp declared_targets(download) do
    case download.targets do
      nil -> [download.target]
      targets -> targets |> Map.values() |> Enum.sort()
    end
  end

  # Downloaded artifacts own their targets exclusively: a chezmoi entry or
  # a declared removal reaching the same path is a composition conflict,
  # checked before the plan exists so replay fails loudly. A dispatched pin
  # declares every platform's destination, and each of them is exclusive.
  @spec check_conflicts([map()], [map()], [map()]) :: :ok
  def check_conflicts(downloads, entries, removals) do
    Enum.each(downloads, fn download ->
      Enum.each(declared_targets(download), fn target ->
        Enum.each(entries, fn entry ->
          overlapping =
            target == entry.target or Paths.encompasses?(target, entry.target) or
              Paths.encompasses?(entry.target, target)

          overlapping &&
            Paths.invalid!(
              "download target #{target} overlaps owned target #{entry.target} " <>
                "(#{Enum.join(entry.attribution, ",")})"
            )
        end)

        Enum.each(removals, fn removal ->
          not Paths.encompasses?(removal.target, target) ||
            Paths.invalid!("declared removal #{removal.target} overlaps download target #{target}")
        end)
      end)
    end)
  end
end
