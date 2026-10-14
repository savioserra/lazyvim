defmodule Workstation.Core.Source.Shell do
  @moduledoc """
  The shell data shape of the source assembler: contributed fragments become
  one backend modify entry per shared target, together with the fragment
  journal the retirement reconciliation reads. The grouping, ordering,
  uniqueness and retirement law lives on the platform
  (`Workstation.Core.Platform.Shell`); the engine-state target law is the
  assembler's cross-shape rule and stays here; the program bytes are the
  contract compositor's.

  Layer: kernel. The kernel law: this module turns grouped shell fragments
  into plan entries and journal records and names no package and no concrete
  provider id.
  """

  alias Workstation.Backends.Chezmoi
  alias Workstation.Core.Contracts.Shell
  alias Workstation.Core.Platform
  alias Workstation.Core.Source.Paths

  @doc """
  One backend modify entry per shared shell target, plus the per-target
  fragment journal for retirement reconciliation.
  """
  @spec compose_shell_entries([map()], map() | nil, %{String.t() => map()}) ::
          {[map()], %{String.t() => [map()]}}
  def compose_shell_entries(collected, journal, ancestors) do
    shell_records = Enum.filter(collected, &(&1.provider == Shell.provider_id()))

    Enum.each(shell_records, fn record ->
      :ok = Paths.assert_not_engine_state!(record.spec.target)
    end)

    grouped =
      shell_records
      |> Platform.Shell.group()
      |> Platform.Shell.retire_disappeared(journal && journal.fragments)

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

      fragments_journal =
        if group.fragments != [],
          do: Map.put(fragments_journal, target, Platform.Shell.journal_records(group)),
          else: fragments_journal

      {entry, fragments_journal}
    end)
  end
end
