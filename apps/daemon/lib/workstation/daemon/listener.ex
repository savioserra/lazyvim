defmodule Workstation.Daemon.Listener do
  @moduledoc """
  The daemon's only socket: an AF_UNIX `:local` stream listener (never
  `:gen_tcp` with a path, and no TCP/`inet` socket exists anywhere in this
  app — a network-reachable daemon would be an unauthenticated control
  channel) that prepares and owns `<home>/.local/state/workstation/daemon/
  <uid>.sock`.

  File guarding is fail-closed at every component:

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

  Per-connection flow: accept, authorize through the boot-resolved socket
  proof (`resolve_proof/2`), then hand the accepted socket to
  `Workstation.Daemon.Session` and flip socket control to it. On Linux the
  proof is the kernel's `SO_PEERCRED` via `:socket.getopt_native(sock,
  {1, 17}, 12)` (the named `:peercred` option is typespec-declared but
  unimplemented in the pinned OTP 28 `:socket` NIF; the bytes are
  `struct ucred` = `{pid, uid, gid}` with the AUTH FIELD second). On darwin
  the kernel mechanism is `LOCAL_PEERCRED`/`getpeereid` (`struct xucred`,
  auth uid also the second field) — probed at boot and used when reachable;
  when it is not reachable without a NIF the dir-owner proof stands in
  instead: the socket lives under the 0700 state root, so a peer that
  connected IS the owner uid and peercred is hardening, not the boundary.
  Which proof a generation runs is recorded in the hello handshake
  (`"proof": "peercred" | "dir-owner"`) and never decided silently. Any
  peer whose uid is not the socket owner's uid is refused. Overflow past
  the session cap refuses the socket immediately instead of queueing
  unbounded state.
  """

  use GenServer

  require Logger

  alias Workstation.Core.EngineState
  alias Workstation.Daemon.{Generation, Protocol, Sessions}

  @daemon_dir "daemon"
  # Linux SOL_SOCKET(1)/SO_PEERCRED(17); 12 bytes = struct ucred.
  @peercred_linux {1, 17}
  @ucred_size 12
  # Darwin SOL_LOCAL(0)/LOCAL_PEERCRED(1); struct xucred = {cr_version,
  # cr_uid, cr_ngroups, cr_groups[16], pad} — the auth uid is the SECOND
  # native int32, exactly like ucred. The read size is generous on purpose:
  # getsockopt returns the OS's own length and the decoder needs only the
  # first 8 bytes.
  @peercred_darwin {0, 1}
  @xucred_size 96
  # The "this platform does not have that option" error family. `:eopnotsupp`
  # is the observed darwin answer to the Linux option; `:enoprotoopt` and
  # `:enotsup` are its kernel-family siblings.
  @unsupported_options [:eopnotsupp, :enoprotoopt, :enotsup]
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

  @doc """
  Decode `struct xucred` bytes (darwin `LOCAL_PEERCRED`) and return the auth
  uid — the SECOND native int32, after `cr_version`. Only the first 8 bytes
  are pinned; the trailing groups array varies across BSD layout revisions.
  """
  @spec xucred_uid(binary()) :: {:ok, non_neg_integer()} | :invalid
  def xucred_uid(raw) when is_binary(raw) and byte_size(raw) >= 8 do
    case raw do
      <<_version::native-unsigned-integer-size(32), uid::native-signed-integer-size(32), _rest::binary>> when uid >= 0 ->
        {:ok, uid}

      _other ->
        :invalid
    end
  end

  def xucred_uid(_other), do: :invalid

  @typedoc """
  The socket-owner proof a daemon generation runs, resolved once at boot:

  * `:peercred` — the kernel answers a peer-credential read (`:ucred` on
    Linux, `:xucred` on darwin); per-connection auth compares the kernel's
    peer uid against the socket owner's uid.
  * `:dir_owner` — the platform has no usable peer-credential read; the
    proof is the ownership chain itself (0700 owned dir + 0600 owned
    socket, re-checked no-follow at accept time). `:why` records why the
    kernel proof was not provable — the audit trail never shows a silent
    weaken.
  """
  @type proof ::
          %{:mode => :peercred, :native => {integer(), integer()}, :flavor => :ucred | :xucred}
          | %{:mode => :dir_owner, :why => term()}

  @doc """
  Resolve this platform's socket-owner proof for the daemon socket. Linux is
  decided by the pre-connection `SO_PEERCRED` sentinel (a well-formed
  12-byte answer proves the option is live; real connections carry real
  creds). When that option is UNSUPPORTED (`:eopnotsupp` family — the
  darwin signature) the darwin arm probes `LOCAL_PEERCRED` and prefers it
  when it answers a well-formed `struct xucred`; anything else on the darwin
  arm degrades EXPLICITLY to the dir-owner proof with the recorded reason —
  the 0700 state root is already the primary boundary there. Every
  NON-unsupported error on the primary (Linux) arm still fails closed:
  `{:error, reason}` — the caller (init) must refuse to become a daemon.
  """
  @spec resolve_proof((() -> :ok | {:error, term()}), (() -> {:ok, binary()} | {:error, term()})) ::
          {:ok, proof()} | {:error, term()}
  def resolve_proof(linux_probe \\ &probe_linux/0, darwin_probe \\ &probe_darwin/0) do
    case linux_probe.() do
      :ok ->
        {:ok, %{mode: :peercred, native: @peercred_linux, flavor: :ucred}}

      {:error, reason} when reason in @unsupported_options ->
        darwin_proof(darwin_probe.())

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp darwin_proof({:ok, raw}) do
    case xucred_uid(raw) do
      {:ok, _uid} ->
        {:ok, %{mode: :peercred, native: @peercred_darwin, flavor: :xucred}}

      :invalid ->
        {:ok, %{mode: :dir_owner, why: {:peercred_unproven, :malformed_xucred}}}
    end
  end

  defp darwin_proof({:error, reason}),
    do: {:ok, %{mode: :dir_owner, why: {:peercred_unproven, reason}}}

  # Pre-connection SO_PEERCRED probe: a well-formed 12-byte answer (the
  # documented pid=0/uid=-1/gid=-1 sentinel included) proves the option is
  # live; the bytes are decoded for real per connection (see ucred_uid/1).
  defp probe_linux do
    probe_native_option(@peercred_linux, @ucred_size, fn
      {:ok, <<_::binary-size(@ucred_size)>>} -> :ok
      {:ok, _other} -> {:error, :malformed_ucred}
      {:error, reason} -> {:error, reason}
    end)
  end

  # Pre-connection LOCAL_PEERCRED probe: darwin answers a well-formed
  # `struct xucred` where the option is reachable (the peer of a real
  # connection carries its real uid, decoded per connection by xucred_uid/1).
  # The expected pre-connection answer on darwin is `:enotconn` — peer creds
  # exist only after a connect, and the pinned OTP has no socketpair to
  # fabricate a connected pair. That outcome is precisely "not reachable
  # without a NIF", so ANY failure here degrades to the recorded dir-owner
  # proof instead of exiting: the boot must survive the platform that gave
  # us no usable option (b6/lane darwin ruling), with the reason on record.
  defp probe_darwin do
    probe_native_option(@peercred_darwin, @xucred_size, fn
      {:ok, raw} when is_binary(raw) -> {:ok, raw}
      {:error, reason} -> {:error, reason}
    end)
  end

  defp probe_native_option(native, size, classify) do
    {:ok, probe} = :socket.open(:local, :stream, :default)

    try do
      classify.(:socket.getopt_native(probe, native, size))
    after
      :ok = :socket.close(probe)
    end
  end

  @doc "The audit-trail marker for a proof, recorded in the hello handshake."
  @spec proof_marker(proof()) :: String.t()
  def proof_marker(%{mode: :peercred}), do: "peercred"
  def proof_marker(%{mode: :dir_owner}), do: "dir-owner"

  @doc """
  The proof resolved by the CURRENT generation's listener (rest_for_one
  boots the registry strictly after the listener, so a served daemon always
  reads a resolved proof here).
  """
  @spec current_proof() :: proof() | :unresolved
  def current_proof, do: :persistent_term.get({__MODULE__, :proof}, :unresolved)

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    home = Keyword.get(opts, :home) || EngineState.home()
    path = socket_path(home)

    # Resolve the socket-owner proof before anything is served. The default
    # (production) path fails closed on a non-unsupported probe error —
    # authentication is the daemon's only trust boundary, so a platform
    # where the kernel proof is BROKEN must refuse to become a daemon at
    # all (supervisor ruling, b6 lane) — while an option-UNSUPPORTED
    # platform (darwin) degrades to the recorded dir-owner proof instead.
    # Tests may force a proof with `proof:` to exercise the non-Linux
    # branches on the Linux CI box.
    proof =
      case Keyword.get(opts, :proof) do
        %{} = forced -> forced
        _other -> resolve_proof!()
      end

    # The registry (rest_for_one: strictly after this listener) snapshots
    # the proof marker into the hello handshake from here.
    :persistent_term.put({__MODULE__, :proof}, proof)

    # Boot-time generation self-check, BEFORE anything is served: pin this
    # node's generation, and when the node PROVABLY is not the installed
    # release (its own root's stamp and the installed release's stamp are
    # both readable and differ) refuse to become a daemon at all — a
    # known-stale node never binds the state socket (the
    # `Workstation.Daemon.Generation` contract; ensure-daemon respawns from
    # the installed release instead).
    own = Generation.pin(opts)

    case Generation.boot_verdict(home, Generation.own_root(opts)) do
      {:stale, ^own, installed} ->
        exit({:stale_generation, own, installed})

      _other ->
        :ok
    end

    sock = bind_or_takeover!(path)
    Logger.info("daemon listening on #{path} pid=#{inspect(self())} proof=#{proof_marker(proof)}")
    {:ok, %{sock: sock, path: path, proof: proof}, {:continue, :accept}}
  end

  @impl true
  def handle_continue(:accept, state) do
    # The listener's only job is this loop; it never handles calls.
    accept_loop(state)
  end

  ## Binding / takeover -------------------------------------------------------

  # The boot-time resolution: `{:error, why}` — a BROKEN kernel proof on the
  # primary platform — refuses to become a daemon. This is the same
  # fail-closed exit the old capability probe raised, still wrapped by the
  # supervisor and mapped by `Workstation.Daemon.Boot`.
  defp resolve_proof! do
    case resolve_proof() do
      {:ok, proof} -> proof
      {:error, why} -> exit({:peercred_unavailable, why})
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
  #
  # Public because the graceful stop (`Workstation.Daemon.Shutdown`) removes
  # the socket node through the SAME proof — one spelling of "this daemon may
  # unlink this path", shared by the takeover and the shutdown.
  @s_ifmt 0o170000
  @s_ifsock 0o140000

  @doc """
  Whether `path` is, no-follow, a socket owned by this uid — the ONLY proof
  that lets the daemon unlink the node: the takeover's stale-socket removal
  and the graceful stop's socket removal both go through this check.
  """
  @spec owned_socket?(String.t()) :: boolean()
  def owned_socket?(path) do
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
    # the per-connection proof in serve_client/2 (kernel peer-credential uid
    # equality, or the dir-owner chain re-check), so the worst case
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

  defp accept_loop(%{sock: sock} = state) do
    case :socket.accept(sock) do
      {:ok, client} ->
        serve_client(client, state)
        accept_loop(state)

      # A closed listener ends the loop; anything else is a blip worth one
      # retry after a short backoff rather than a hot spin.
      {:error, :closed} ->
        exit(:shutdown)

      {:error, _reason} ->
        Process.sleep(10)
        accept_loop(state)
    end
  end

  # The per-connection path is CRASH-PROOF BY CONSTRUCTION: this listener is
  # the FIRST child of a rest_for_one tree, so one raise here would roll the
  # WHOLE serving generation — killing every session and cutting every
  # in-flight op's connection mid-frame (the client sees a daemon death on a
  # read-only op). A per-connection failure must cost exactly that
  # connection: log it, close the refused socket, keep accepting.
  defp serve_client(client, %{path: path, proof: proof}) do
    try do
      do_serve_client(client, path, proof)
    catch
      kind, value ->
        Logger.error(
          "daemon listener: per-connection path failed (#{inspect(kind)}:#{inspect(value)}); " <>
            "the connection is refused, the listener keeps accepting path=#{path}"
        )

        _ = :socket.close(client)
        :ok
    end
  end

  defp do_serve_client(client, path, proof) do
    case connection_peer_uid(client, path, proof) do
      {:ok, peer_uid} ->
        hand_off(client, path, peer_uid)

      :refused ->
        # Refused peers learn only that the connection went away; credential
        # errors, foreign uids and a broken ownership chain are all "closed".
        Logger.warning("daemon refused connection on #{path}")
        _ = :socket.close(client)
        :ok
    end
  end

  # Peercred mode: the kernel answers the CONNECTED socket with the peer's
  # credentials and uid equality is the auth. The Linux path — this clause,
  # the read shape and the decode are byte-identical to the original ruling.
  defp connection_peer_uid(client, _path, %{mode: :peercred, native: native, flavor: flavor}) do
    with {:ok, raw} <- :socket.getopt_native(client, native, cred_size(flavor)),
         {:ok, peer_uid} <- decode_peer_uid(raw, flavor),
         true <- peer_uid == EngineState.uid() do
      {:ok, peer_uid}
    else
      _ -> :refused
    end
  end

  # Dir-owner mode: no kernel peer-credential read is provable on this
  # platform, so the proof is the ownership chain itself, RE-CHECKED at
  # accept time — a 0700 directory owned by this uid plus a socket owned by
  # this uid, both no-follow. Connecting to a unix socket requires search
  # permission on every directory component and write on the socket node, so
  # a peer that connected IS the owner uid; the marker in the hello
  # handshake keeps the weaker (but primary, on that platform) boundary
  # visible in the audit trail.
  defp connection_peer_uid(_client, path, %{mode: :dir_owner}) do
    if dir_owner_proof?(path), do: {:ok, EngineState.uid()}, else: :refused
  end

  defp dir_owner_proof?(path) do
    case EngineState.lstat(Path.dirname(path)) do
      %{type: "directory", uid: uid, mode: mode} ->
        uid == EngineState.uid() and :erlang.band(mode, 0o077) == 0 and owned_socket?(path)

      _other ->
        false
    end
  end

  defp decode_peer_uid(raw, :ucred), do: ucred_uid(raw)
  defp decode_peer_uid(raw, :xucred), do: xucred_uid(raw)

  defp cred_size(:ucred), do: @ucred_size
  defp cred_size(:xucred), do: @xucred_size

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
