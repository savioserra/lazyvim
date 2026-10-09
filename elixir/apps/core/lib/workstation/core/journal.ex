defmodule Workstation.Core.Journal do
  @moduledoc """
  Layer: kernel. The kernel law: this module names no package, no backend and no
  consumer -- it speaks only contracts and shapes (docs/architecture.md,
  "Module hierarchy & moduledoc conventions").
The private per-target journal under the engine state root: guarded reads and
the guarded write path.

The journal is the sole provenance record for owned targets; every
precondition and baseline decision binds to it. Reading is side-effect free
and fail-closed on invariants (no-follow, owner checks in
`Workstation.Core.EngineState`), while malformed entries resolve to absent
results — a half-decoded record must never be
mistaken for a proven ownership claim.

Writes are exclusive and atomic: every record lands through a same-directory
`wx` temp file at 0600 renamed over the target, so a crashed write can never
leave a torn journal entry, and every write path first repairs-and-verifies
its guarded directory chain (0700, owned, no-follow). A failed backend run is
recorded under `journal/failed/` — recovery from a partial apply is
conflict-aware through the journal, never a blind replay.
"""

  alias Workstation.Core.EngineState

  @doc """
  The applied record (generation, revision, targets, fragments, manifest,
  source_index) or `nil` when no generation was ever applied or the entry is
  malformed.
  """
  @spec applied(String.t()) :: map() | nil
  def applied(state_root) do
    case verify_journal_tree() do
      :ok ->
        case EngineState.read_json(Path.join([state_root, "journal", "applied.json"])) do
          {:ok, record} when is_map(record) -> record
          _other -> nil
        end

      :absent ->
        nil
    end
  end

  @doc """
  Pending attempt records, sorted by file name.
  Malformed entries are skipped: pending evidence without a decodable body is
  noise, not provenance. Each record carries its `"file"` name so callers can
  reference attempts without re-deriving the path.
  """
  @spec pending(String.t()) :: [map()]
  def pending(state_root) do
    # A missing journal root answers "no pending attempts" (the write path
    # creates it on first write); a violated guard must still raise.
    case verify_journal_tree() do
      :absent ->
        []

      :ok ->
        pending_records(state_root)
    end
  end

  defp pending_records(state_root) do
    directory = Path.join([state_root, "journal", "pending"])

    case EngineState.lstat(directory) do
      nil ->
        []

      %{type: "directory"} ->
        directory
        |> File.ls!()
        |> Enum.sort()
        |> Enum.flat_map(fn name ->
          case EngineState.read_json(Path.join(directory, name)) do
            # Map.put (not the structural-update syntax): pending files written
            # by an older engine revision may lack the file slot; this
            # projection freely adds it.
            {:ok, record} when is_map(record) -> [Map.put(record, "file", name)]
            _other -> []
          end
        end)

      _other ->
        raise ArgumentError, "pending journal root is not a directory"
    end
  end

  # The walked chain must include the `journal` component itself, guarded
  # like every state component (0700, no-follow, current uid): Erlang
  # `:file.read_link_info` lstats only the final
  # component, so without this walk a symlinked `journal` directory would be
  # read through into unrelated state — and applied/pending records are the
  # ownership provenance feeding preconditions and changeset baselines.
  # `:absent` (no journal yet, nothing ever applied) is the callers' "empty"
  # answer, never a mutation: this side never creates the directory.
  @spec verify_journal_tree() :: :ok | :absent
  defp verify_journal_tree do
    EngineState.verify_tree!(EngineState.home(), EngineState.state_components() ++ ["journal"], "journal root")
  end

  @doc "Fingerprint one owned target (type, mode, digest/link); `nil` when absent or unsupported."
  @spec target_fingerprint(String.t(), String.t()) :: map() | nil
  defdelegate target_fingerprint(home, target), to: EngineState

  @doc "Lowercase hex SHA-256 of binary contents."
  @spec sha256(binary()) :: String.t()
  defdelegate sha256(contents), to: EngineState

  # --- guarded write path ---------------------------------------------------
  # The pending/failed/applied record writers. Every function takes the
  # target `home` because the guarded chain is anchored there; records are
  # plain string-keyed maps and encode through
  # `Workstation.Core.CanonicalJSON`, whose exact bytes the journal's
  # readers decode.

  @doc """
  Record one in-flight apply attempt before the backend runs, as
  `journal/pending/<generation>.json` with generation, timestamp, pid, entry
  count and the exact target list. A pending record is the recovery anchor:
  preconditions refuse a new generation whose desired targets neither match
  it nor cover its touched targets, so a crashed attempt is surfaced, never
  silently forgotten.
  """
  @spec write_pending(String.t(), map()) :: :ok
  def write_pending(home, %{} = record) do
    generation = Map.fetch!(record, "generation")
    assert_generation!(generation)

    directory = ensure_journal_directory!(home, "pending")
    write_json(Path.join(directory, "#{generation}.json"), record)
  end

  @doc """
  Record a failed backend run under `journal/failed/` (unique per attempt:
  `<generation>-<time>-<seq>.json`). The note travels with the record because
  the honest semantics matter: a failed apply may have partially applied, and
  recovery is conflict-aware through the journal, never a blind replay.
  """
  @spec write_failed(String.t(), String.t(), term()) :: :ok
  def write_failed(home, generation, error) do
    assert_generation!(generation)

    directory = ensure_journal_directory!(home, "failed")
    name = "#{generation}-#{System.system_time(:second)}-#{System.unique_integer([:positive])}.json"

    record = %{
      "generation" => generation,
      "at" => System.system_time(:second),
      "pid" => os_pid(),
      "error" => error_string(error),
      "note" => "partial apply is possible; recovery is conflict-aware, never a blind replay"
    }

    write_json(Path.join(directory, name), record)
  end

  @doc """
  Write the applied provenance record (`journal/applied.json`): generation,
  monotonic revision (previous + 1), timestamp, per-target fingerprints,
  fragment journal, manifest and source index. This record is the ownership
  claim every later precondition and baseline check trusts, so the generation
  identifier is re-validated and the record is written atomically.
  """
  @spec record_applied(String.t(), String.t(), map(), term(), [map()], map()) :: :ok
  def record_applied(home, generation, targets, fragments, manifest, source_index) do
    assert_generation!(generation)

    # The applied record is the ownership claim every later precondition and
    # baseline check trusts, and the readers demand object shapes (a JSON
    # array decodes as a list, which silently poisons the journal — the
    # 2026-10-05 real-host incident). Fail closed at the sole write site
    # instead of ever recording a journal no reader can consume.
    unless is_map(targets),
      do: raise(ArgumentError, "journal record targets must be a JSON object; got #{inspect(targets)}")

    unless is_map(source_index),
      do: raise(ArgumentError, "journal record source index must be a JSON object; got #{inspect(source_index)}")

    unless is_list(manifest),
      do: raise(ArgumentError, "journal record manifest must be a JSON array; got #{inspect(manifest)}")

    previous = applied(Path.join([home | EngineState.state_components()])) || %{}

    record = %{
      "generation" => generation,
      "revision" => (previous["revision"] || 0) + 1,
      "at" => System.system_time(:second),
      "targets" => targets,
      "fragments" => fragments,
      "manifest" => manifest,
      "source_index" => source_index
    }

    directory = ensure_journal_directory!(home, nil)
    write_json(Path.join(directory, "applied.json"), record)
  end

  @doc """
  Clear every pending attempt record. Names are asserted against the strict
  `<hex>.json` shape first: an unexpected entry under `journal/pending/` is a
  corruption signal, never something to sweep away.
  """
  @spec clear_pending(String.t()) :: :ok
  def clear_pending(home) do
    directory = Path.join([home | EngineState.state_components() ++ ["journal", "pending"]])

    case EngineState.lstat(directory) do
      nil ->
        :ok

      %{type: "directory"} ->
        Enum.each(File.ls!(directory), fn name ->
          unless Regex.match?(~r/\A[0-9a-f]+\.json\z/, name),
            do: raise(ArgumentError, "unexpected pending record name: #{name}")

          File.rm!(Path.join(directory, name))
        end)

        :ok

      _other ->
        raise ArgumentError, "pending journal root is not a directory"
    end
  end

  # The whole chain is created-or-repaired guarded: intermediates 0755,
  # every journal component 0700, no-follow, owned. The `journal` root is
  # always ensured first as its own
  # 0700 final (before any leaf), so a fresh
  # walk never creates it at an intermediate's 0755 and the leaf chain then
  # passes through it untouched.
  defp ensure_journal_directory!(home, leaf) do
    components = EngineState.state_components() ++ ["journal"]
    :ok = EngineState.ensure_tree!(home, components, "journal root")
    label = if leaf, do: "#{leaf} journal root", else: "journal root"
    :ok = EngineState.ensure_tree!(home, components ++ List.wrap(leaf), label)
    Path.join([home | components ++ List.wrap(leaf)])
  end

  defp assert_generation!(generation) do
    unless EngineState.valid_generation_id(generation),
      do: raise(ArgumentError, "journal record has an invalid generation identifier")
  end

  # Exclusive same-directory temp + rename, mode 0600: a reader either sees
  # the previous record or the complete new one, never a torn write, and the
  # private mode is set before the record becomes visible under its name.
  defp write_json(path, value) do
    directory = Path.dirname(path)
    temp = Path.join(directory, ".#{Path.basename(path)}.#{os_pid()}-#{System.unique_integer([:positive])}.tmp")

    file = File.open!(temp, [:write, :exclusive])

    try do
      # Object-faithful encoding: journal readers require map shapes for
      # targets/source_index/fragments, so an empty map records as {} — the
      # envelope's empty-object-as-[] rule (pinned by the goldens) must not
      # poison state.
      IO.binwrite(file, Workstation.Core.CanonicalJSON.encode_record(value))
      File.chmod!(temp, 0o600)
    after
      File.close(file)
    end

    File.rename!(temp, path)
    :ok
  end

  defp os_pid, do: :os.getpid()

  defp error_string(%{__exception__: true} = error), do: Exception.message(error)
  defp error_string(error) when is_binary(error), do: error
  defp error_string(error), do: inspect(error)
end
