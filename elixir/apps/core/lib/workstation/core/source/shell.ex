defmodule Workstation.Core.Source.Shell do
  @moduledoc """
  The shell data shape of the source assembler: contributed fragments group
  per shared target in collection order and compose into one backend modify
  entry per target, together with the journal fragment records the
  retirement reconciliation reads. Pure — no I/O.

  Layer: kernel. The kernel law: one deterministic modify entry per shared
  target — fragments group in collection order, explicit order keys break
  ties, and one marker on one target has one owning fragment.
  """

  alias Workstation.Backends.Chezmoi
  alias Workstation.Core.Contracts.Shell
  alias Workstation.Core.Source.Paths

  @doc """
  One backend modify entry per shared shell target (explicit journal-aware:
  targets whose every recorded fragment disappeared still recompose once so
  their exact known blocks are removed), and the per-target fragment journal
  for retirement reconciliation.
  """
  @spec compose_shell_entries([map()], map() | nil, %{String.t() => map()}) ::
          {[map()], %{String.t() => [map()]}}
  def compose_shell_entries(collected, journal, ancestors) do
    grouped = desired_fragments(collected)

    # Targets whose every recorded fragment disappeared still need one final
    # recomposition so their exact known blocks are removed; leftover managed
    # shell lines are not inert and stopping source management is not removal.
    grouped =
      case journal && journal.fragments do
        nil -> grouped
        recorded -> Enum.reduce(recorded, grouped, fn {target, applied}, acc ->
          if Map.has_key?(acc, target) or applied == [] do
            acc
          else
            Map.put(acc, target, %{target: target, fragments: [], owners: []})
          end
        end)
      end

    Enum.map_reduce(grouped, %{}, fn {target, group}, fragments_journal ->
      recorded = (journal && journal.fragments && Map.get(journal.fragments, target)) || %{}
      {program, _ids} = Shell.compose(target, group.fragments, recorded)

      recipe =
        Chezmoi.recipe(%{target: target, kind: :modify, executable: true, content: program})

      entry = %{
        owner: "shell",
        provider: Chezmoi.provider_id(),
        operation: "modify",
        target: target,
        source_name: Chezmoi.source_name(recipe, ancestors),
        type: "modify",
        mode: Chezmoi.entry_mode(recipe),
        bytes: program,
        shared: true,
        attribution: group.owners,
        fragments: group.fragments
      }

      # Journal fragment records: {id, marker, body, order, owner, sequence}
      # with sequence the 1-based position of the shell record in collection
      # order (string keys — the journal is recorded state, encoded
      # canonically).
      fragments_journal =
        if group.fragments != [] do
          journal_records =
            Enum.map(group.fragments, fn fragment ->
              %{
                "id" => fragment.id,
                "marker" => fragment.marker,
                "body" => fragment.body,
                "order" => fragment.order,
                "owner" => fragment.owner,
                "sequence" => fragment.sequence
              }
            end)

          Map.put(fragments_journal, target, journal_records)
        else
          fragments_journal
        end

      {entry, fragments_journal}
    end)
  end

  # Group shell fragments per shared target in collection order; explicit
  # fragment order keys plus graph-order tie-breaking keep output stable.
  # One marker on one target can only ever have one owning fragment id.
  defp desired_fragments(collected) do
    collected
    |> Enum.filter(&(&1.provider == Shell.provider_id()))
    |> Enum.with_index(1)
    |> Enum.reduce(%{}, fn {record, sequence}, grouped ->
      :ok = Shell.validate_spec(record.spec)
      :ok = Paths.assert_not_engine_state!(record.spec.target)
      target = record.spec.target

      group =
        Map.get_lazy(grouped, target, fn -> %{target: target, fragments: [], owners: []} end)

      fragment = %{
        id: record.spec.fragment.id,
        marker: record.spec.fragment.marker,
        body: record.spec.fragment.body,
        order: record.spec.fragment.order,
        owner: record.owner,
        sequence: sequence
      }

      group = %{
        target: target,
        fragments: group.fragments ++ [fragment],
        owners: group.owners ++ [record.owner]
      }

      Map.put(grouped, target, group)
    end)
    |> Enum.map(fn {target, group} ->
      fragments =
        Enum.sort_by(group.fragments, fn fragment -> {fragment.order, fragment.sequence} end)

      ids = MapSet.new(Enum.map(fragments, & &1.id))

      if MapSet.size(ids) != length(fragments) do
        Paths.invalid!("duplicate shell fragment id on #{target}")
      end

      # One marker on one target can only ever have one owning fragment:
      # this fold exists to detect the duplicate and fails closed — no
      # state escapes it.
      Enum.reduce(fragments, MapSet.new(), fn fragment, seen ->
        MapSet.member?(seen, fragment.marker) &&
          Paths.invalid!(
            "duplicate shell marker #{fragment.marker} on #{target} is owned by both " <>
              "an earlier fragment and #{fragment.id}"
          )

        MapSet.put(seen, fragment.marker)
      end)

      {target, %{group | fragments: fragments}}
    end)
    |> Map.new()
  end
end
