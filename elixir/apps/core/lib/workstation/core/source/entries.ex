defmodule Workstation.Core.Source.Entries do
  @moduledoc """
  The entries data shape of the source assembler: chezmoi recipes become
  plan entries (with content-addressed fingerprints) or explicit removals,
  and directory declarations build the ancestor table the shared
  source-name encoding reads. Pure — validated recipes in, entry maps out.

  Layer: kernel. The kernel law: a validated recipe becomes a plan entry
  with a content-addressed fingerprint or an explicit removal, and the
  module names no concrete package and no provider id.
  """

  alias Workstation.Backends.Chezmoi
  alias Workstation.Core.Digest
  alias Workstation.Core.Source.Paths

  # Directory ancestors: one validated declaration table per directory
  # target, with incompatible attribute combinations failing closed — the
  # shared source-name encoding and the conflict detector read this table.
  @spec build_ancestors([map()]) :: %{String.t() => map()}
  def build_ancestors(collected) do
    Enum.reduce(collected, %{}, fn record, ancestors ->
      if record.provider == Chezmoi.provider_id() and record.spec.kind == :directory do
        :ok = Chezmoi.validate_spec(record.spec)

        existing = Map.get(ancestors, record.spec.target)

        if existing != nil and (existing.exact != record.spec.exact or existing.private != record.spec.private) do
          Paths.invalid!("incompatible directory attributes for #{record.spec.target}")
        end

        Map.put(ancestors, record.spec.target, %{exact: record.spec.exact, private: record.spec.private})
      else
        ancestors
      end
    end)
  end

  @doc """
  The chezmoi share of the collection: every recipe becomes a plan entry or
  an explicit removal (carried as `{entries, removals}`).
  """
  @spec build_entries([map()], %{String.t() => map()}) :: {[map()], [map()]}
  def build_entries(collected, ancestors) do
    collected
    |> Enum.filter(&(&1.provider == Chezmoi.provider_id()))
    |> Enum.map_reduce([], fn record, removals ->
      :ok = Chezmoi.validate_spec(record.spec)
      :ok = Paths.assert_not_engine_state!(record.spec.target)

      case build_entry(record, ancestors) do
        {{:removal, target, owner}, _acc} ->
          {nil, removals ++ [%{target: target, owner: owner}]}

        {entry, _acc} ->
          {entry, removals}
      end
    end)
    |> then(fn {entries, removals} -> {Enum.reject(entries, &is_nil/1), removals} end)
  end

  defp build_entry(record, ancestors) do
    spec = record.spec

    if spec.kind == :remove do
      # Explicit removals have no source name; they become .chezmoiremove
      # entries carried by the policy body.
      {{:removal, spec.target, record.owner}, []}
    else
      # Every generated regular source file must carry real bytes: a nil body
      # must never silently publish an empty program or payload.
      bytes =
        cond do
          spec.kind == :symlink -> spec.to
          spec.kind == :directory -> nil
          true -> spec.content
        end

      unless spec.kind == :symlink or spec.kind == :directory or bytes != nil do
        Paths.invalid!("backend file recipe produced no source bytes for #{spec.target}")
      end

      type =
        cond do
          spec.kind == :symlink -> "link"
          spec.kind == :modify -> "modify"
          true -> Atom.to_string(spec.kind)
        end

      entry = %{
        owner: record.owner,
        provider: Chezmoi.provider_id(),
        operation: Atom.to_string(spec.kind),
        target: spec.target,
        source_name: Chezmoi.source_name(spec, ancestors),
        type: type,
        mode: Chezmoi.entry_mode(spec),
        bytes: bytes,
        link: if(spec.kind == :symlink, do: spec.to),
        exact: spec.exact,
        template: spec.template,
        attribution: attribution(record),
        fingerprint: fingerprint(spec, type, bytes)
      }

      {entry, []}
    end
  end

  defp attribution(record), do: Map.get(record, :attribution) || [record.owner]

  # Fingerprints are content addresses: the encode is canonical (bytewise key
  # order) so two processes derive the identical id for identical content.
  defp fingerprint(spec, type, bytes) do
    fields =
      [
        {"target", spec.target},
        {"operation", Atom.to_string(spec.kind)},
        {"type", type},
        {"mode", Chezmoi.entry_mode(spec)},
        {"bytes", bytes && Digest.sha256(bytes)},
        {"link", if(spec.kind == :symlink, do: spec.to)}
      ]
      |> Enum.reject(fn {_key, value} -> value == nil end)
      |> Map.new()

    Digest.sha256(Workstation.Core.CanonicalJSON.encode(fields))
  end
end
