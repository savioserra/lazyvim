defmodule Workstation.Core.EngineState do
  @moduledoc """
  Layer: kernel. The kernel law: this module names no package, no backend and no
  consumer -- it speaks only contracts and shapes (docs/architecture.md,
  "Module hierarchy & moduledoc conventions").
  Guarded read access to the target-private engine state tree
  (`<home>/.local/state/workstation`) and to owned home targets.

  Every path the providers touch MUST go through these primitives, because
  the engine guarantees the invariants here and nowhere else:

  * engine-state paths are resolved without following symlinks (`lstat`,
    never `stat`) — a redirected `.local/state` chain must fail closed
    instead of silently reading through a link into unrelated state;
  * every engine-state component must be a real directory owned by the
    current account, and the state root must hold exactly mode 0700
    (journal records carry fingerprints of private home state);
  * journal-derived generation identifiers are validated before any path is
    built from them (a hash-shaped string alone is never trusted);
  * the write-side primitives (`ensure_tree!/4`) create directory chains
    per-component, no-follow, owned, with the final component repaired to
    the exact private mode — the state root may legitimately exist at 0755
    (runtime-root creation) and is repaired on first engine write, never
    read through a foreign owner.

  The read primitives stay side-effect free: an absent tree resolves to
  "absent" results (an earlier engine would create it), never to a mutation.
  Mutations happen only inside `ensure_tree!/4` and behind the callers that
  gate every write on it (journal records, generation staging, apply lock).
  """

  require Record
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  @state_components [".local", "state", "workstation"]
  @state_mode 0o700
  # Intermediates of a created state chain are world-traversable like the
  # anchor's 493; the private mode belongs to the final component only.
  @intermediate_mode 0o755

  @doc """
  Target home: `WORKSTATION_HOME` wins over `HOME`
  (the CLI passes `--home` through `WORKSTATION_HOME`), must be absolute.
  """
  @spec home() :: String.t()
  def home do
    home = System.get_env("WORKSTATION_HOME") || System.get_env("HOME")

    unless is_binary(home) and String.starts_with?(home, "/") do
      raise ArgumentError, "target home must be absolute"
    end

    Path.expand(home)
  end

  @doc "Engine state root: `<home>/.local/state/workstation`, never an ambient XDG root."
  @spec state_root() :: String.t()
  def state_root, do: Path.join([home(), ".local", "state", "workstation"])

  @doc "State tree components below `home`, for `verify_tree!/4` callers."
  @spec state_components() :: [String.t()]
  def state_components, do: @state_components

  @doc """
  Guard all engine roots below `home` before any engine write or record:
  the state root, `generations/` and `journal/`, each final at 0700. This is
  the write-side root contract: every mutation and every
  journal record assumes the private guarded tree exists, and letting each
  writer improvise its own creation order is how a journal lands at 0755.
  """
  @spec ensure_roots!(String.t()) :: :ok
  def ensure_roots!(home) do
    :ok = ensure_tree!(home, @state_components, "state root")
    :ok = ensure_tree!(home, @state_components ++ ["generations"], "generations root")
    :ok = ensure_tree!(home, @state_components ++ ["journal"], "journal root")
  end

  @doc """
  Join a validated relative target to the destination home, mirroring
  `state.join_home`: non-empty, never absolute, never a control byte or NUL.
  `..` traversal is rejected earlier at recipe level; this guard only asserts
  what join_home itself can prove.
  """
  @spec join_home(String.t(), term()) :: String.t()
  def join_home(home, target) do
    unless is_binary(target) and target != "" and not String.starts_with?(target, "/") do
      raise ArgumentError, "invalid relative target"
    end

    if String.contains?(target, "\0") or String.match?(target, ~r/[\x00-\x1f\x7f]/) do
      raise ArgumentError, "invalid target characters"
    end

    Path.join(home, target)
  end

  @doc """
  Valid content-addressed generation identifier: exactly 64 lowercase hex
  characters. Checked before it ever becomes a path component.
  """
  @spec valid_generation_id(term()) :: boolean()
  def valid_generation_id(id) do
    is_binary(id) and byte_size(id) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, id)
  end

  @doc """
  Generation directory for a journal-derived identifier, verified no-follow
  when it exists: a symlink or non-directory under the generations root is a
  corruption signal, never something to read through.
  """
  @spec generation_directory(String.t(), term()) :: String.t()
  def generation_directory(root, id) do
    unless valid_generation_id(id), do: raise(ArgumentError, "journal records an invalid generation identifier")

    directory = Path.join([root, "generations", id])

    case lstat(directory) do
      nil ->
        directory

      %{type: "directory", uid: owner} ->
        unless owner == uid(),
          do: raise(ArgumentError, "recorded generation is not owned by the current account: #{directory}")

        directory

      _other ->
        raise ArgumentError, "recorded generation is not a directory: #{directory}"
    end
  end

  @doc """
  Verify the engine state tree below `home` no-follow and owned, with the
  final component holding exactly `final_mode`. Returns `:absent` when the
  walk stops at the first missing component (the read path treats that as an
  absent journal), `:ok` when everything checks out, and raises on any
  existing component that violates the invariants. Creation and repair live
  on the write path; this read path never mutates.
  """
  @spec verify_tree!(String.t(), [String.t()], String.t(), non_neg_integer()) :: :ok | :absent
  def verify_tree!(home, components, label, final_mode \\ @state_mode)

  def verify_tree!(_home, [], _label, _final_mode), do: :ok

  def verify_tree!(home, components, label, final_mode) do
    final = Path.join([home | components])

    case walk_guarded(home, components, label) do
      :missing ->
        :absent

      :ok ->
        stat = lstat(final)
        stat.mode == final_mode || raise(ArgumentError, "#{label} has mode #{octal(stat.mode)}, expected #{octal(final_mode)}: #{final}")

        :ok
    end
  end

  defp walk_guarded(base, components, label) do
    Enum.reduce_while(components, base, fn component, current ->
      current = Path.join(current, component)

      case lstat(current) do
        nil ->
          {:halt, :missing}

        %{type: "directory", uid: owner} ->
          unless owner == uid(),
            do: raise(ArgumentError, "#{label} component is not owned by the current account: #{current}")

          {:cont, current}

        _other ->
          raise ArgumentError, "#{label} component is not a directory: #{current}"
      end
    end)
    |> case do
      :missing -> :missing
      _final_path -> :ok
    end
  end

  @doc """
  Create-or-verify a guarded directory chain below `home`, the write-side
  twin of `verify_tree!/4`: intermediates are created at 0755 when absent (an
  existing one is only checked no-follow for type and current-account
  ownership — never re-chmodded, so a 0700 journal root
  walked through by a deeper chain keeps its private mode) and the final
  component is created at `final_mode` or, when it already exists, checked
  and repaired to `final_mode`, because the repair is how a legitimately
  0755 state root reaches the exact private mode. Anything else (a symlinked
  component, a foreign owner, a file where a directory belongs) raises
  instead of being written through.
  """
  @spec ensure_tree!(String.t(), [String.t()], String.t(), non_neg_integer()) :: :ok
  def ensure_tree!(home, components, label, final_mode \\ @state_mode)

  def ensure_tree!(_home, [], _label, _final_mode), do: :ok

  def ensure_tree!(home, components, label, final_mode) do
    final = Path.join([home | components])
    final_index = length(components)

    {_current, _index} =
      Enum.reduce(components, {home, 0}, fn component, {current, index} ->
        next = Path.join(current, component)
        index = index + 1
        wanted_mode = if index == final_index, do: final_mode, else: @intermediate_mode

        case lstat(next) do
          nil ->
            File.mkdir!(next)
            File.chmod!(next, wanted_mode)

          %{type: "directory", mode: mode, uid: owner} ->
            unless owner == uid(),
              do: raise(ArgumentError, "#{label} component is not owned by the current account: #{next}")

            # The repair is deliberate (the existing final component is
            # chmod'ed on every write-path access) and applies to the final
            # component only: an existing intermediate keeps its mode, so a
            # 0700 journal root passed through by a deeper chain is never
            # widened to 0755.
            if index == final_index and mode != wanted_mode, do: File.chmod!(next, wanted_mode)

          _other ->
            raise ArgumentError, "#{label} component is not a directory: #{next}"
        end

        {next, index}
      end)

    stat = lstat(final)
    stat.mode == final_mode || raise(ArgumentError, "#{label} has mode #{octal(stat.mode)}, expected #{octal(final_mode)}: #{final}")

    :ok
  end

  @doc """
  Guard one journal file before reading: must exist as a regular file owned
  by the current account, or be absent. Returns `:absent` or `:ok`, raises on
  a violated invariant.
  """
  @spec guard_file!(String.t()) :: :ok | :absent
  def guard_file!(path) do
    case lstat(path) do
      nil ->
        :absent

      %{type: "file", uid: owner} ->
        unless owner == uid(),
          do: raise(ArgumentError, "engine journal entry is not owned by the current account: #{path}")

        :ok

      _other ->
        raise ArgumentError, "engine journal entry is not a regular file: #{path}"
    end
  end

  @doc """
  No-follow stat of one path: `%{type: "file" | "directory" | "link" | "other",
  mode, uid, size}` with `mode` masked to the permission bits (the low
  12 bits), or `nil` when absent. Symlinks report
  `"link"` and are never dereferenced.
  """
  @spec lstat(String.t()) ::
          %{type: String.t(), mode: non_neg_integer(), uid: non_neg_integer(), size: non_neg_integer()} | nil
  def lstat(path) do
    # read_link_info is lstat semantics: the entry itself is described and a
    # symlink is never dereferenced, so guards and fingerprints cannot be
    # redirected through a planted link (read_file_info would follow it).
    case :file.read_link_info(path, [:raw, {:time, :posix}]) do
      {:ok, info} ->
        %{
          type: lu_type(file_info(info, :type)),
          mode: :erlang.band(file_info(info, :mode), 0o7777),
          uid: file_info(info, :uid),
          size: file_info(info, :size)
        }

      {:error, _reason} ->
        nil
    end
  end

  defp lu_type(:regular), do: "file"
  defp lu_type(:directory), do: "directory"
  defp lu_type(:symlink), do: "link"
  defp lu_type(_other), do: "other"

  defp octal(mode), do: Integer.to_string(mode, 8)

  @doc "Current account uid, cached: every ownership check compares against it."
  @spec uid() :: non_neg_integer()
  def uid do
    case :persistent_term.get({__MODULE__, :uid}, :missing) do
      :missing ->
        {output, 0} = System.cmd("id", ["-u"])
        parsed = output |> String.trim() |> String.to_integer()
        :persistent_term.put({__MODULE__, :uid}, parsed)
        parsed

      parsed ->
        parsed
    end
  end

  @doc "Read a guarded file's bytes: `{:ok, binary}`, `:absent`, or raises on guard failure."
  @spec read_file(String.t()) :: {:ok, binary()} | :absent
  def read_file(path) do
    case guard_file!(path) do
      :absent -> :absent
      :ok -> {:ok, File.read!(path)}
    end
  end

  @doc """
  Read a private journal JSON file without following symlinks. Absent entries
  decode as `:absent`; malformed content is `{:error, :malformed}` — never a
  raw body and never a crash.
  """
  @spec read_json(String.t()) :: {:ok, term()} | :absent | {:error, :malformed}
  def read_json(path) do
    case read_file(path) do
      :absent -> :absent
      {:ok, contents} -> decode_json(contents)
    end
  end

  @doc "Lowercase hex SHA-256, the journal's content-address function."
  @spec sha256(binary()) :: String.t()
  def sha256(contents) when is_binary(contents) do
    Base.encode16(:crypto.hash(:sha256, contents), case: :lower)
  end

  @doc """
  Fingerprint actual owned target state: type, permission bits, content
  digest or link value. Reads only metadata, link values and content digests;
  home-file bodies are never copied into engine state. Unsupported target
  types (sockets, devices) resolve to `nil`, so callers treat them as
  "changed", never as something to overwrite.
  """
  @spec target_fingerprint(String.t(), String.t()) :: map() | nil
  def target_fingerprint(home, target) do
    path = join_home(home, target)

    case lstat(path) do
      nil ->
        nil

      %{type: "file", mode: mode} ->
        # The guarded lstat above already excluded symlinks, so this open
        # cannot be redirected between check and read.
        %{"type" => "file", "mode" => mode, "sha256" => sha256(File.read!(path))}

      %{type: "link", mode: mode} ->
        {:ok, link} = File.read_link(path)
        %{"type" => "link", "mode" => mode, "link" => link}

      %{type: "directory", mode: mode} ->
        %{"type" => "directory", "mode" => mode}

      _other ->
        nil
    end
  end

  # --- Minimal strict JSON decoding -----------------------------------------
  #
  # The journal is written by `vim.json.encode`; the reader accepts that
  # dialect (RFC 8259). Decoding is fail-closed: any malformed byte sequence
  # yields `{:error, :malformed}` instead of a partial value, because a
  # half-decoded journal record would be a falsified ownership claim.
  # The parser itself lives in `Workstation.Core.JSON`.

  @spec decode_json(binary()) :: {:ok, term()} | {:error, :malformed}
  def decode_json(binary) when is_binary(binary), do: Workstation.Core.JSON.decode(binary)
end
