defmodule Workstation.Daemon.Listener do
  @moduledoc """
  The daemon's only socket: an AF_UNIX `:local` stream listener (never
  `:gen_tcp` with a path, and no TCP/`inet` socket exists anywhere in this
  app — a network-reachable daemon would be an unauthenticated control
  channel) that prepares and owns `<home>/.local/state/workstation/daemon/
  <uid>.sock`.

  File guarding mirrors `state.lua` `guarded_directory`:

  * the daemon state directory is created 0700 and verified with lstat
    semantics (type `directory`, owner uid) — a symlinked directory or one
    owned by another uid is a redirection attempt and fails the boot;
  * the socket file itself must be a socket owned by this uid, never
    followed through a link; anything else at the path is refused, never
    deleted, so an unrelated file can never be destroyed by the daemon.

  Stale-socket takeover is deliberately fail-closed: on `EADDRINUSE` the
  listener probes the endpoint (connect + version handshake). A peer that
  completes the handshake is a live daemon and startup fails with
  `:already_running`; a connect-refused or handshake-silent endpoint is dead
  and is unlinked (only after the no-follow owner/type re-check) and rebound.
  A connected-but-mute endpoint is treated as dead for takeover exactly
  because a killed daemon's socket can still complete handshakes from the
  kernel backlog — the handshake, not the connect, is the liveness signal.

  Per-connection flow: accept, read `SO_PEERCRED` via
  `:socket.getopt_native(sock, {1, 17}, 12)` (the named `:peercred` option is
  typespec-declared but unimplemented in the pinned OTP 28 `:socket` NIF;
  the bytes are `struct ucred` = `{pid, uid, gid}` with the AUTH FIELD second),
  refuse any peer whose uid is not the socket owner's uid, then hand the
  accepted socket to `Workstation.Daemon.Session` and flip socket control to
  it. Overflow past the session cap refuses the socket immediately instead of
  queueing unbounded state.
  """

  use GenServer

  require Logger

  alias Workstation.Core.EngineState
  alias Workstation.Daemon.{Protocol, Sessions}

  @daemon_dir "daemon"
  # Linux SOL_SOCKET(1)/SO_PEERCRED(17); 12 bytes = struct ucred.
  @peercred_native {1, 17}
  @ucred_size 12
  @probe_timeout_ms 2_000
  @socket_mode 0o600
  @dir_mode 0o700

  @doc "Socket path for a home: `<home>/.local/state/workstation/daemon/<uid>.sock`."
  @spec socket_path(String.t(), pos_integer() | nil) :: String.t()
  def socket_path(home, uid \\ nil) do
    uid = uid || EngineState.uid()
    Path.join([home, ".local", "state", "workstation", @daemon_dir, "#{uid}.sock"])
  end

  @doc "Socket path under the current WORKSTATION_HOME (ambient-home callers only)."
  @spec socket_path() :: String.t()
  def socket_path, do: socket_path(EngineState.home())

  @doc "Decode `struct ucred` bytes and return the auth uid (the SECOND field)."
  @spec ucred_uid(binary()) :: {:ok, non_neg_integer()} | :invalid
  def ucred_uid(<<_pid::native-signed-integer-size(32), uid::native-signed-integer-size(32), _gid::native-signed-integer-size(32)>>)
      when uid >= 0,
      do: {:ok, uid}

  def ucred_uid(_other), do: :invalid

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    home = Keyword.get(opts, :home) || EngineState.home()
    path = socket_path(home)

    # Fail closed before anything is served: authentication is the daemon's
    # only trust boundary, so a platform where peercred is unreadable must
    # refuse to become a daemon at all (supervisor ruling, b6 lane).
    assert_peercred_capability!()
    sock = bind_or_takeover!(path)
    Logger.info("daemon listening on #{path} pid=#{inspect(self())}")
    {:ok, %{sock: sock, path: path}, {:continue, :accept}}
  end

  @impl true
  def handle_continue(:accept, state) do
    # The listener's only job is this loop; it never handles calls.
    accept_loop(state.sock, state.path)
  end

  ## Binding / takeover -------------------------------------------------------

  # Capability probe for the native SO_PEERCRED read used by auth. The named
  # `:peercred` socket option is typespec-declared but unimplemented in the
  # pinned OTP 28 `:socket` NIF, so support is established at boot via the
  # raw (level 1, opt 17) form; anything else exits and the tree never boots.
  @spec assert_peercred_capability!() :: :ok
  def assert_peercred_capability! do
    {:ok, probe} = :socket.open(:local, :stream, :default)

    verdict =
      try do
        case :socket.getopt_native(probe, @peercred_native, @ucred_size) do
          # A pre-connection socket answers with the documented sentinel
          # (pid=0, uid=-1, gid=-1); any well-formed 12-byte ucred proves the
          # option is live. Real connections carry real creds (see ucred_uid/1).
          {:ok, <<_::binary-size(@ucred_size)>>} -> :ok

          {:ok, _other} ->
            {:peercred_unavailable, :malformed_ucred}

          {:error, reason} ->
            {:peercred_unavailable, reason}
        end
      after
        :ok = :socket.close(probe)
      end

    case verdict do
      :ok -> :ok
      {:peercred_unavailable, why} -> exit({:peercred_unavailable, why})
    end
  end

  defp bind_or_takeover!(path) do
    ensure_daemon_dir!(Path.dirname(path))

    case try_bind(path) do
      {:ok, sock} ->
        prep!(sock, path)

      {:error, :eaddrinuse} ->
        takeover!(path)

      {:error, reason} ->
        exit({:bind_failed, reason})
    end
  end

  defp try_bind(path) do
    case :socket.open(:local, :stream, :default) do
      {:ok, sock} ->
        case :socket.bind(sock, %{family: :local, path: String.to_charlist(path)}) do
          :ok -> {:ok, sock}
          {:error, reason} -> _ = :socket.close(sock)
                             {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp takeover!(path) do
    case probe_peer(path) do
      :alive ->
        # A live generation owns the endpoint; a second listener must never
        # fight it for the bind. The caller (start_link) surfaces this as
        # {:error, {:already_running, path}}.
        exit({:already_running, path})

      :dead ->
        unlink_owned_socket!(path)

        case try_bind(path) do
          {:ok, sock} -> prep!(sock, path)
          {:error, :eaddrinuse} -> exit({:bind_failed, :eaddrinuse_after_takeover})
          {:error, reason} -> exit({:bind_failed, reason})
        end
    end
  end

  # Connect + version handshake. The handshake completing (any bytes of a
  # reply) means a live server; connect refusal or handshake silence means a
  # dead endpoint.
  defp probe_peer(path) do
    with {:ok, client} <- :socket.open(:local, :stream, :default),
         :ok <- :socket.connect(client, %{family: :local, path: String.to_charlist(path)}, @probe_timeout_ms) do
      hello = Protocol.encode_frame(Jason.encode!(%{"v" => 1, "id" => "takeover-probe", "op" => "hello", "params" => %{"protocol" => Protocol.protocol_name()}}))

      result =
        case :socket.send(client, hello) do
          :ok -> recv_any(client, @probe_timeout_ms)
          {:error, _reason} -> :dead
        end

      _ = :socket.close(client)
      if result == :alive, do: :alive, else: :dead
    else
      # Anything but a completed handshake is a dead endpoint: refusal,
      # timeout, or a non-socket file at the path. Fail closed to :dead so a
      # takeover can only ever unlink a provably unreachable endpoint.
      {:error, _reason} -> :dead
    end
  end

  defp recv_any(sock, budget) do
    case :socket.recv(sock, 1, budget) do
      {:ok, _bytes} -> :alive
      {:error, _reason} -> :dead
    end
  end

  # Deleting the stale socket only after a fresh no-follow check that it is
  # still a socket owned by this uid: between the failed bind and this check
  # the path may have been replaced by anything, and the daemon never deletes
  # a file it cannot prove it owns.
  defp unlink_owned_socket!(path) do
    case owned_socket?(path) do
      true ->
        case File.rm(path) do
          :ok -> :ok
          {:error, reason} -> exit({:stale_socket_unlink_failed, reason})
        end

      false ->
        exit({:socket_path_not_owned, path})
    end
  end

  # S_IFMT/S_IFSOCK file-type bits: EngineState.lstat collapses sockets, fifos
  # and devices into type "other", so the socket-path guard must read the raw
  # mode bits — otherwise a regular file planted at the socket path would pass
  # the ownership check and be deleted on takeover. The daemon only ever
  # unlinks what it can PROVE is its own dead socket node.
  @s_ifmt 0o170000
  @s_ifsock 0o140000

  defp owned_socket?(path) do
    case File.lstat(path) do
      {:ok, stat} ->
        :erlang.band(stat.mode, @s_ifmt) == @s_ifsock and stat.uid == EngineState.uid()

      {:error, _reason} ->
        false
    end
  end

  defp prep!(sock, path) do
    :ok = :socket.listen(sock)

    unless owned_socket?(path) do
      _ = :socket.close(sock)
      exit({:socket_path_not_owned, path})
    end

    # Harden to 0600 immediately after the no-follow ownership check. The
    # mode is defense-in-depth, not the auth: a foreign uid that somehow
    # connected (0700 dir + this chmod as the barriers) is still refused by
    # the SO_PEERCRED uid equality check in serve_client/2, so the worst case
    # of a lost chmod race is a refused connection, never an authorized one.
    # (No umask dance: file:umask/1 is not exported by the pinned OTP's
    # file module — probed undef at runtime.)
    case File.chmod(path, @socket_mode) do
      :ok ->
        sock

      {:error, reason} ->
        _ = :socket.close(sock)
        exit({:socket_chmod_failed, reason})
    end
  end
  defp ensure_daemon_dir!(dir) do
    case File.mkdir_p(dir) do
      :ok ->
        case EngineState.lstat(dir) do
          %{type: type, uid: uid, mode: mode} ->
            cond do
              type == "link" -> exit({:daemon_dir_is_symlink, dir})
              uid != EngineState.uid() -> exit({:daemon_dir_not_owned, dir})
              # Already-correct dirs are left alone; wrong modes are repaired
              # (mirrors guarded_directory's repair step) after the no-follow
              # checks above.
              :erlang.band(mode, 0o077) != 0 -> File.chmod!(dir, @dir_mode)
              true -> :ok
            end

          _other ->
            exit({:daemon_dir_unusable, dir})
        end

      {:error, reason} ->
        exit({:daemon_dir_create_failed, reason})
    end
  end

  ## Accept loop ---------------------------------------------------------------

  defp accept_loop(sock, path) do
    case :socket.accept(sock) do
      {:ok, client} ->
        serve_client(client, path)
        accept_loop(sock, path)

      # A closed listener ends the loop; anything else is a blip worth one
      # retry after a short backoff rather than a hot spin.
      {:error, :closed} ->
        exit(:shutdown)

      {:error, _reason} ->
        Process.sleep(10)
        accept_loop(sock, path)
    end
  end

  defp serve_client(client, path) do
    with {:ok, raw} <- :socket.getopt_native(client, @peercred_native, @ucred_size),
         {:ok, peer_uid} <- ucred_uid(raw),
         true <- peer_uid == EngineState.uid() do
      hand_off(client, path, peer_uid)
    else
      # Refused peers learn only that the connection went away; credential
      # errors and foreign uids are all just "closed".
      _ ->
        Logger.warning("daemon refused connection on #{path}")
        _ = :socket.close(client)
        :ok
    end
  end

  defp hand_off(client, path, peer_uid) do
    case Sessions.start_session(sock: client, sock_path: path, peer_uid: peer_uid) do
      {:ok, session} ->
        # Control transfer in the `:socket` API is the :otp controlling_process
        # setopt: from here the session owns reads/writes/closes on the fd.
        case :socket.setopt(client, :otp, :controlling_process, session) do
          :ok ->
            send(session, :begin)
            :ok

          {:error, reason} ->
            Logger.error("daemon control hand-off failed: #{inspect(reason)}")
            _ = :socket.close(client)
            :ok
        end

      {:error, :max_children} ->
        # Overflow is a refusal, not a queue: an unbounded backlog is denial-
        # of-service state the daemon would have to babysit.
        Logger.warning("daemon at session cap; refusing connection")
        _ = :socket.close(client)
        :ok

      {:error, reason} ->
        Logger.error("daemon session start failed: #{inspect(reason)}")
        _ = :socket.close(client)
        :ok
    end
  end
end
