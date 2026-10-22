defmodule Workstation.Core.EngineState do
  @moduledoc """
  Layer: kernel. The kernel law: this module names no package, no backend and no
  consumer -- it speaks only contracts and shapes (docs/architecture.md,
  "Module hierarchy & moduledoc conventions").
  Guarded read access to the target-private engine state tree
  (`<home>/.local/state/workstation`) and to owned home targets.

  Every path the read plane touches MUST go through these primitives, because
  the engine guarantees the invariants here and nowhere else:

  * engine-state paths are resolved without following symlinks (`lstat`,
    never `stat`) — a redirected `.local/state` chain must fail closed
    instead of silently reading through a link into unrelated state;
  * every engine-state component must be a real directory owned by the
    current account, and the state root must hold exactly mode 0700
    (private state is never read through a foreign owner or a widened
    chain).

  The read primitives stay side-effect free: an absent tree resolves to
  "absent" results, never to a mutation. The engine writes nothing — the
  nix substrate owns the write plane (its own state tree lives under the
  nix store and the profile generations).
  """

  require Record
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  @state_components [".local", "state", "workstation"]
  @state_mode 0o700

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

  @doc "State tree components below `home`."
  @spec state_components() :: [String.t()]
  def state_components, do: @state_components

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
  Verify the engine state tree below `home` no-follow and owned, with the
  final component holding exactly `final_mode`. Returns `:absent` when the
  walk stops at the first missing component (the read path treats that as an
  absent state root), `:ok` when everything checks out, and raises on any
  existing component that violates the invariants. This read path never
  mutates.
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

  @doc "Lowercase hex SHA-256, the engine's content-address function."
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
  # The journal is written through CanonicalJSON.encode_record/1; the
  # reader accepts that dialect (RFC 8259). Decoding is fail-closed: any malformed byte sequence
  # yields `{:error, :malformed}` instead of a partial value, because a
  # half-decoded journal record would be a falsified ownership claim.
  # The parser itself lives in `Workstation.Core.JSON`.

  @spec decode_json(binary()) :: {:ok, term()} | {:error, :malformed}
  def decode_json(binary) when is_binary(binary), do: Workstation.Core.JSON.decode(binary)
end
