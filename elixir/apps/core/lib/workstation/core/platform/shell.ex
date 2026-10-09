defmodule Workstation.Core.Platform.Shell do
  @moduledoc """
  The shared-shell fragment platform: the envelope, ordering and journal law
  every shell contribution rides, over the one compositor
  (`Workstation.Core.Contracts.Shell.compose/3`, whose emitted program bytes
  ARE the deployed source state).

  A fragment is the envelope `%{id, marker, body, order}` — a stable marker
  plus a literal single-line body, an explicit order key with collection
  order as the tie-break. This platform owns everything the law requires of
  fragments: envelope validation (the atom-keyed declared shape), per-target
  grouping with fragment-id and marker uniqueness, the string-keyed journal
  projection, and the retirement rule (a target whose every recorded
  fragment disappeared still recomposes once, so leftover managed lines are
  removed). What it does not own: program generation — the compositor's
  emitted bytes are the contract — and the pre-backend block verification of
  the actual file, which is the shared compositor module's
  (`Workstation.Core.ShellProgram.validate_target/3`).

  Layer: platform. The platform law: this module names no consumer and no
  backend — packages declare fragments, the assembler groups and composes
  them, and the compositor's program bytes are the only deployed shape.
  """

  alias Workstation.Core.Contracts.Shell

  @doc """
  The fragment envelope law: exactly the `%{id, marker, body, order}` fields,
  the three strings non-empty and single-line, the order key a positive
  integer. Returns the fragment unchanged; raises `ArgumentError` otherwise.
  """
  @spec validate_fragment(term()) :: :ok
  def validate_fragment(fragment) do
    unless is_map(fragment), do: invalid("shell fragment must be a table")

    for field <- Map.keys(fragment) do
      unless field in [:id, :marker, :body, :order] do
        invalid("shell fragment has unknown field #{inspect(field)}")
      end
    end

    nonempty_string?(fragment[:id]) || invalid("shell fragment requires an id")
    nonempty_string?(fragment[:marker]) || invalid("shell fragment requires a marker")
    nonempty_string?(fragment[:body]) || invalid("shell fragment requires a body")

    order = fragment[:order]

    unless is_integer(order) and order > 0 do
      invalid("shell fragment requires a positive integer order")
    end

    # Ids, markers and bodies are embedded in generated shell comments and
    # programs; control bytes and newlines could not survive literally.
    reject_control(fragment[:id], "shell fragment id")
    reject_control(fragment[:marker], "shell fragment marker")
    reject_control(fragment[:body], "shell fragment body")
    :ok
  end

  @doc """
  The shared-target law: a relative destination-home path, no backslashes,
  no control bytes, no traversal. Returns the target unchanged.
  """
  @spec validate_target_path(term()) :: :ok
  def validate_target_path(target) do
    nonempty_string?(target) || invalid("shell recipe requires a target")
    String.starts_with?(target, "/") && invalid("shell target must be relative to the destination home: #{target}")
    String.contains?(target, "\\") && invalid("shell target must not contain backslashes: #{target}")

    if String.match?(target, ~r/[\x00-\x1f\x7f]/) do
      invalid("shell target must not contain control characters or newlines")
    end

    target
    |> String.split("/", trim: true)
    |> Enum.each(fn component ->
      component in [".", ".."] && invalid("shell target must not traverse: #{target}")
    end)

    :ok
  end

  defp nonempty_string?(value), do: is_binary(value) and value != ""

  defp reject_control(value, label) do
    String.match?(value, ~r/[\x00-\x1f\x7f]/) &&
      invalid("#{label} must not contain control characters or newlines")

    :ok
  end

  defp invalid(message), do: raise(ArgumentError, message)

  @typedoc "One grouped target: the ordered fragments and their owners."
  @type group :: %{required(:target) => String.t(), required(:fragments) => [map()], required(:owners) => [String.t()]}

  @typedoc "One collected shell record, as the assembler gathers it."
  @type record :: %{required(:owner) => String.t(), required(:spec) => Shell.t()}

  @doc """
  Group collected shell records per shared target in collection order;
  explicit fragment order keys plus collection order as tie-break keep every
  group's output stable. Every spec is re-validated through the contract,
  and the group law fails closed: one fragment id and one marker per target,
  each rejection naming the target.
  """
  @spec group([record()]) :: %{String.t() => group()}
  def group(records) when is_list(records) do
    records
    |> Enum.with_index(1)
    |> Enum.reduce(%{}, fn {record, sequence}, grouped ->
      :ok = Shell.validate_spec(record.spec)
      target = record.spec.target

      group = Map.get_lazy(grouped, target, fn -> %{target: target, fragments: [], owners: []} end)

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
    |> Enum.map(fn {target, group} -> {target, finish_group(group)} end)
    |> Map.new()
  end

  # Per-target group law: explicit order key with the collection sequence as
  # the stable tie-break; one fragment id per target; one marker per target.
  defp finish_group(group) do
    fragments = Enum.sort_by(group.fragments, fn fragment -> {fragment.order, fragment.sequence} end)

    ids = MapSet.new(Enum.map(fragments, & &1.id))

    if MapSet.size(ids) != length(fragments) do
      raise(ArgumentError, "duplicate shell fragment id on #{group.target}")
    end

    # One marker on one target can only ever have one owning fragment: this
    # fold exists to detect the duplicate and fails closed — no state
    # escapes it.
    Enum.reduce(fragments, MapSet.new(), fn fragment, seen ->
      MapSet.member?(seen, fragment.marker) &&
        raise(
          ArgumentError,
          "duplicate shell marker #{fragment.marker} on #{group.target} is owned by both " <>
            "an earlier fragment and #{fragment.id}"
        )

      MapSet.put(seen, fragment.marker)
    end)

    %{group | fragments: fragments}
  end

  @doc """
  The string-keyed journal projection of one group's fragments — the
  recorded state the golden envelopes pin and the pre-backend verification
  reads. Sequence stays the 1-based collection position, so the recorded
  order is machine-independent.
  """
  @spec journal_records(group()) :: [map()]
  def journal_records(%{fragments: fragments}) do
    Enum.map(fragments, fn fragment ->
      %{
        "id" => fragment.id,
        "marker" => fragment.marker,
        "body" => fragment.body,
        "order" => fragment.order,
        "owner" => fragment.owner,
        "sequence" => fragment.sequence
      }
    end)
  end

  @doc """
  Retirement recomposition: targets whose every recorded fragment
  disappeared still get one empty group, so their exact known blocks are
  removed once — leftover managed shell lines are not inert, and stopping
  source management is not removal. `journal_fragments` is the recorded
  string-keyed map (nil when the journal is fresh).
  """
  @spec retire_disappeared(%{String.t() => group()}, map() | nil) :: %{String.t() => group()}
  def retire_disappeared(grouped, journal_fragments)

  def retire_disappeared(grouped, nil), do: grouped

  def retire_disappeared(grouped, recorded) do
    Enum.reduce(recorded, grouped, fn {target, applied}, acc ->
      if Map.has_key?(acc, target) or applied == [] do
        acc
      else
        Map.put(acc, target, %{target: target, fragments: [], owners: []})
      end
    end)
  end

end
