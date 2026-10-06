defmodule Workstation.CLI.DaemonClient do
  @moduledoc """
  The CLI's daemon protocol client — the thin-client half of the engine
  client/server split. Every verb dispatch reduces to: ensure the daemon is
  up (`ensure/1`), send one op, render the result. There is NO in-process
  fallback for any verb: the daemon is the only mutation engine and the
  only source of live state, so a daemon that cannot be reached or spawned
  is a clear operator error, never a silent reimplementation.

  `ensure/1` resolves the destination home's socket; when the socket is
  absent or dead it spawns a daemon DETACHED from the same release binary
  (`<release>/bin/workstation daemon`) with `WORKSTATION_HOME` pinned to the
  destination, then waits — bounded — for the versioned hello handshake.
  Stopping the daemon stays manual (`workstation daemon stop`).

  Wire: the daemon's own `Workstation.Daemon.Protocol` frames (4-byte
  big-endian length + JSON), reused verbatim so the client cannot drift
  from the server. One connection per op; the op response closes it. The
  daemon advertises its pinned home in the hello capabilities; a mismatch
  with the client's resolved home is refused before any op is sent — `--home`
  must never silently talk to a daemon serving another home.
  """

  alias Workstation.Core.EngineState
  alias Workstation.Daemon.{Listener, Protocol}

  @connect_timeout_ms 1_000
  @handshake_timeout_ms 2_000
  @spawn_wait_ms 10_000
  @poll_ms 200
  @default_timeout_ms 120_000
  @control_timeout_ms 5_000

  @type error ::
          {:error, {String.t(), String.t()}}
          | {:error, {:daemon_unavailable, String.t()}}
          | {:error, {:daemon_died, String.t()}}

  @doc """
  Ensure a daemon serves `home` and return an authenticated socket.

  Options:

    * `:home` — the destination home (default: `WORKSTATION_HOME`, else
      `HOME` — the same resolution the Router does; the daemon compares its
      own pinned home against exactly this value).
    * `:spawner` — `fun(home, socket_path) :: :ok | {:error, String.t()}`,
      the detach-and-spawn seam (tests start the tree in-process instead).
    * `:connect_timeout_ms` / `:handshake_timeout_ms` — socket budgets for
      the probe; the spawn wait is additionally bounded by
      `:spawn_wait_ms` (default #{@spawn_wait_ms}).
  """
  @spec ensure(keyword()) :: {:ok, :socket.socket()} | {:error, {:daemon_unavailable, String.t()}}
  def ensure(opts \\ []) do
    home = Keyword.get(opts, :home) || EngineState.home()
    sock_path = Listener.socket_path(home)

    case handshake(sock_path, home, opts) do
      {:ok, sock} ->
        {:ok, sock}

      :unavailable ->
        with :ok <- spawn_daemon(home, sock_path, opts) do
          await_handshake(sock_path, home, opts, now_ms() + spawn_wait(opts))
        end

      {:error, {:daemon_unavailable, _}} = error ->
        error
    end
  end

  @doc """
  Run one op against the destination home's daemon. Ensures the daemon
  first, opens one connection, speaks hello, sends the op, and returns the
  op result.

  Returns `{:ok, result}` with the daemon's result map, or:

    * `{:error, {code, message}}` — the daemon refused the op (`locked`,
      `core`, `engine`, `unknown_op`, ...); the caller maps codes to exit
      codes.
    * `{:error, {:daemon_unavailable, message}}` — no daemon and none could
      be spawned (missing release, spawn failure, handshake timeout).
    * `{:error, {:daemon_died, message}}` — the daemon died mid-op. There
      is no in-process fallback; the only legal resume path is the update
      handoff contract, which lives with the update verb.

  Options: `:home`, `:timeout_ms` (op budget, default #{@default_timeout_ms};
  lifecycle ops pass a longer budget since lock queues and engine steps can
  take minutes), `:spawner`, `:connect_timeout_ms`, `:handshake_timeout_ms`.
  """
  @spec call(String.t(), map(), keyword()) :: {:ok, map()} | error()
  def call(op, params, opts \\ []) when is_binary(op) and is_map(params) and is_list(opts) do
    home = Keyword.get(opts, :home) || EngineState.home()

    with {:ok, sock} <- ensure(Keyword.put(opts, :home, home)) do
      try do
        request(sock, op, params, opts)
      after
        :socket.close(sock)
      end
    end
  end

  @doc """
  Send one op to an ALREADY-RUNNING daemon — the no-spawn path used by
  control surfaces (`workstation daemon stop`, `op.abort`): control must
  never start anything. Returns the op result, or `{:error, reason}` when
  no daemon is reachable (worded for direct operator display).
  """
  @spec control(String.t(), map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def control(op, params \\ %{}, opts \\ []) when is_binary(op) and is_map(params) and is_list(opts) do
    case control_with_pid(op, params, opts) do
      {:ok, result, _daemon_pid} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  `control/2` plus the daemon's OS pid, captured from the connected
  socket's `SO_PEERCRED` before the request. `workstation daemon stop`
  needs the pid to CONFIRM the beam actually exits after the acknowledged
  stop before printing "stopped" (`Workstation.CLI.Control.confirm_exit/2`) —
  the daemon's own halt can wedge, and it did (a beam alive 7m41s after
  `daemon: stopped`). The pid is the PEER's ucred pid — the mirror image of
  the daemon's own per-connection auth read
  (`Workstation.Daemon.Listener`), so it is as reliable as the connection
  itself; on any failure it is `nil` and the caller refuses to report
  success unverified.

  Returns `{:ok, result, daemon_pid}` (`daemon_pid` is a positive integer
  or `nil`), or `{:error, reason}` shaped exactly like `control/2`.
  """
  @spec control_with_pid(String.t(), map(), keyword()) ::
          {:ok, map(), pos_integer() | nil} | {:error, String.t()}
  def control_with_pid(op, params \\ %{}, opts \\ [])
      when is_binary(op) and is_map(params) and is_list(opts) do
    home = Keyword.get(opts, :home) || EngineState.home()
    sock_path = Listener.socket_path(home)
    hello_timeout = Keyword.get(opts, :handshake_timeout_ms, @handshake_timeout_ms)
    op_timeout = Keyword.get(opts, :timeout_ms, @control_timeout_ms)

    with {:ok, sock} <- reach(sock_path, home, hello_timeout) do
      daemon_pid = peer_pid(sock)

      try do
        case request(sock, op, params, timeout_ms: op_timeout) do
          {:ok, result} -> {:ok, result, daemon_pid}
          # The structural {code, message} op-refusal shape is matched LAST:
          # the tagged client-side failures (daemon_died/timeout/unavailable)
          # are the same tuple arity and must render as plain messages.
          {:error, {:daemon_died, message}} -> {:error, message}
          {:error, {:timeout, message}} -> {:error, message}
          {:error, {:daemon_unavailable, message}} -> {:error, message}
          {:error, {code, message}} -> {:error, "#{code}: #{message}"}
        end
      after
        :socket.close(sock)
      end
    end
  end

  @doc """
  Abort an in-flight op by its stream token (every event frame carries the
  `op_ref`; the TUI forwards it from the first run event). Rides a second,
  short-lived control connection — the daemon honours cross-session aborts
  through its op registry, and the op stops at the NEXT STEP BOUNDARY: a
  cancelled mutation is never killed half-way. Best-effort by contract: a
  racing finish answers `aborted: false` and surfaces as an error message,
  never a crash.
  """
  @spec abort(String.t(), keyword()) :: :ok | {:error, String.t()}
  def abort(op_ref, opts \\ []) when is_binary(op_ref) do
    case control("op.abort", %{"op_ref" => op_ref}, opts) do
      {:ok, %{"aborted" => true}} -> :ok
      {:ok, %{"aborted" => false}} -> {:error, "no running op for that stream token"}
      {:error, message} -> {:error, message}
    end
  end

  # Connect + hello for control surfaces; daemon_unavailable folds to a
  # plain "no daemon" message (the caller displays it verbatim).
  defp reach(sock_path, home, hello_timeout) do
    case handshake(sock_path, home, handshake_timeout_ms: hello_timeout) do
      {:ok, sock} -> {:ok, sock}
      :unavailable -> {:error, "no daemon is running for home #{home}"}
      {:error, {:daemon_unavailable, message}} -> {:error, message}
    end
  end

  # SO_PEERCRED of the CONNECTED client socket answers the PEER's (the
  # daemon's) `struct ucred` — pid first, same 12 bytes the daemon decodes
  # per connection (`Workstation.Daemon.Listener.ucred_uid/1`). Raw form
  # `(level 1, opt 17)` because the named option is unimplemented in the
  # pinned OTP 28 `:socket` NIF. Best-effort: `nil` just means the stop
  # verb cannot verify the exit and must refuse to claim success.
  defp peer_pid(sock) do
    case :socket.getopt_native(sock, {1, 17}, 12) do
      {:ok,
       <<pid::native-signed-integer-size(32), _uid::native-signed-integer-size(32),
         _gid::native-signed-integer-size(32)>>}
      when pid > 0 ->
        pid

      _other ->
        nil
    end
  end

  ## wire

  # One request on an already-helloed socket. Events interleaved ahead of
  # the response are consumed through `opts[:on_event]` (the streaming half
  # of the protocol); an unexpected socket death is a daemon death.
  defp request(sock, op, params, opts) do
    id = "cli-#{System.unique_integer([:positive])}"
    deadline = now_ms() + Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    frame = Jason.encode!(%{"v" => Protocol.version(), "id" => id, "op" => op, "params" => params})

    case :socket.send(sock, Protocol.encode_frame(frame)) do
      :ok -> await_response(sock, id, deadline, opts)
      {:error, reason} -> {:error, {:daemon_died, "send failed: #{inspect(reason)}"}}
    end
  end

  defp await_response(sock, id, deadline, opts) do
    case read_frame(sock, deadline) do
      {:ok, %{"id" => ^id, "ok" => true, "result" => result}} ->
        {:ok, restore_null_tokens(result)}

      {:ok, %{"id" => ^id, "ok" => false, "error" => %{"code" => code, "message" => message}}} ->
        {:error, {code, message}}

      {:ok, %{"event" => _event} = event} ->
        consume_event(event, opts)
        await_response(sock, id, deadline, opts)

      {:ok, other} ->
        {:error, {:daemon_died, "unexpected frame shape: #{inspect(other)}"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp consume_event(%{"event" => event}, opts) do
    case Keyword.get(opts, :on_event) do
      fun when is_function(fun, 1) -> fun.(event)
      _other -> :ok
    end
  end

  # The wire's JSON nulls carry schema meaning (the canonical :null token —
  # required-present keys like the status journal). Jason.decode delivers
  # them as nil, and the canonical render would then DROP those keys, so the
  # token is restored here: every daemon path and the offline --input path
  # hand the renderer the same wire flavor. Exact, not heuristic: the daemon
  # emits null only through the canonical :null token, so any decoded nil WAS
  # a token.
  defp restore_null_tokens(%{} = value), do: Map.new(value, fn {k, v} -> {k, restore_null_tokens(v)} end)
  defp restore_null_tokens(list) when is_list(list), do: Enum.map(list, &restore_null_tokens/1)
  defp restore_null_tokens(nil), do: :null
  defp restore_null_tokens(other), do: other

  # One length-prefixed frame, bounded by the absolute op deadline. A
  # deadline breach reads as a timeout error, a peer close as daemon death.
  @spec read_frame(:socket.socket(), integer()) ::
          {:ok, map()} | {:error, {:daemon_died, String.t()}} | {:error, {:timeout, String.t()}}
  defp read_frame(sock, deadline) do
    header_budget = max(deadline - now_ms(), 1)

    case :socket.recv(sock, Protocol.header_length(), header_budget) do
      {:ok, <<length::unsigned-big-integer-size(32)>>} ->
        body_budget = max(deadline - now_ms(), 1)
        read_body(sock, length, body_budget, [])

      {:ok, _partial} ->
        {:error, {:daemon_died, "short frame header from daemon"}}

      {:error, :closed} ->
        {:error, {:daemon_died, "daemon closed the connection"}}

      {:error, :timeout} ->
        {:error, {:timeout, "daemon did not answer within the op budget"}}

      {:error, reason} ->
        {:error, {:daemon_died, "recv failed: #{inspect(reason)}"}}
    end
  end

  defp read_body(_sock, 0, _budget, chunks) do
    case Jason.decode(IO.iodata_to_binary(Enum.reverse(chunks))) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:daemon_died, "undecodable frame: #{inspect(reason)}"}}
    end
  end

  defp read_body(sock, remaining, budget, chunks) do
    case :socket.recv(sock, remaining, budget) do
      {:ok, data} -> read_body(sock, remaining - byte_size(data), budget, [data | chunks])
      {:error, :closed} -> {:error, {:daemon_died, "daemon closed the connection mid-frame"}}
      {:error, :timeout} -> {:error, {:timeout, "daemon did not answer within the op budget"}}
      {:error, reason} -> {:error, {:daemon_died, "recv failed: #{inspect(reason)}"}}
    end
  end

  ## handshake

  # Connect + versioned hello + pinned-home check. Wire failures fold to
  # :unavailable (the caller decides between spawning and reporting); the
  # pinned-home mismatch is a distinct, actionable daemon_unavailable.
  defp handshake(sock_path, home, opts) do
    connect_timeout = Keyword.get(opts, :connect_timeout_ms, @connect_timeout_ms)
    hello_timeout = Keyword.get(opts, :handshake_timeout_ms, @handshake_timeout_ms)

    case :socket.open(:local, :stream, :default) do
      {:ok, sock} ->
        result =
          with :ok <-
                 :socket.connect(sock, %{family: :local, path: String.to_charlist(sock_path)}, connect_timeout),
               {:ok, capabilities} <- hello(sock, hello_timeout),
               :ok <- home_matches?(capabilities, home, sock_path) do
            {:ok, sock}
          else
            _other -> :unavailable
          end

        case result do
          {:ok, sock} -> {:ok, sock}
          other ->
            _ = :socket.close(sock)
            other
        end

      {:error, _reason} ->
        :unavailable
    end
  rescue
    # A hostile or wedged peer must cost at most one closed socket, never a
    # client crash.
    _error -> :unavailable
  end

  defp hello(sock, timeout) do
    frame =
      Jason.encode!(%{
        "v" => Protocol.version(),
        "id" => "cli-hello",
        "op" => "hello",
        "params" => %{"protocol" => Protocol.protocol_name()}
      })

    with :ok <- :socket.send(sock, Protocol.encode_frame(frame)),
         {:ok, %{"ok" => true, "result" => result}} <- read_frame(sock, now_ms() + timeout),
         %{"protocol" => protocol} <- result,
         true <- protocol == Protocol.protocol_name() do
      {:ok, result}
    else
      _other -> :unavailable
    end
  end

  # The daemon serves exactly one home; the client compares it against the
  # home THIS invocation resolved (possibly --home). A mismatch is refused:
  # an op set without a home parameter plus this advertisement is what
  # keeps `--home` honest — a mismatch is a loud operator error, never a
  # silent mutation of some other home.
  defp home_matches?(%{"home" => daemon_home}, home, _sock_path) when is_binary(daemon_home) do
    if daemon_home == home do
      :ok
    else
      {:error,
       {:daemon_unavailable,
        "daemon is serving a different home (#{daemon_home}); stop it with " <>
          "`workstation daemon stop` or point --home at #{daemon_home}"}}
    end
  end

  defp home_matches?(%{"home" => _other}, _home, _sock_path) do
    {:error, {:daemon_unavailable, "daemon did not report a usable home; refusing to guess"}}
  end

  # Older daemons without the home advertisement cannot be trusted with a
  # pinned-home op set — the client refuses rather than guesses.
  defp home_matches?(_capabilities, _home, sock_path) do
    {:error,
     {:daemon_unavailable,
      "daemon at #{sock_path} does not advertise its home (protocol too old); " <>
        "stop it and let the client spawn a current daemon"}}
  end

  ## spawn

  defp spawn_daemon(home, sock_path, opts) do
    case Keyword.get(opts, :spawner) || (&default_spawner/3) do
      fun when is_function(fun, 3) -> fun.(home, sock_path, spawn_env(home, opts))
    end
  end

  # The spawn environment: the inherited env with WORKSTATION_HOME pinned
  # to the destination, plus WORKSTATION_ENGINE_REPO when the operator
  # passed --engine-root (the same override the one-shot engine honored).
  defp spawn_env(home, opts) do
    env = Map.put(System.get_env(), "WORKSTATION_HOME", home)

    case opts[:engine_root] do
      nil -> env
      root -> Map.put(env, "WORKSTATION_ENGINE_REPO", Path.expand(root))
    end
  end

  # Spawn detached from the SAME release binary the client itself runs from:
  # `<release>/bin/workstation daemon`, nohup'd so the daemon survives this
  # short-lived client VM, stdio into the daemon state dir's log (boot
  # failures stay diagnosable), env pinned via `spawn_env/2`.
  defp default_spawner(_home, sock_path, env) do
    bin = release_bin()

    if File.regular?(bin) do
      daemon_dir = Path.dirname(sock_path)
      File.mkdir_p!(daemon_dir)
      log = Path.join(daemon_dir, "daemon.log")

      cmd = "nohup \"#{bin}\" daemon >>\"#{log}\" 2>&1 </dev/null &"

      case System.cmd("/bin/sh", ["-c", cmd], env: env) do
        {_out, 0} -> :ok
        {out, code} -> {:error, "daemon spawn failed (exit #{code}): #{String.trim(out)}"}
      end
    else
      {:error,
       "no release binary at #{bin}; the workstation daemon can only be started " <>
         "from an installed release (run `workstation bootstrap` first)"}
    end
  end

  defp release_bin, do: Path.join([:code.root_dir() |> to_string(), "bin", "workstation"])

  defp await_handshake(sock_path, home, opts, deadline) do
    case handshake(sock_path, home, opts) do
      {:ok, sock} ->
        {:ok, sock}

      {:error, {:daemon_unavailable, _}} = error ->
        error

      :unavailable ->
        if now_ms() >= deadline do
          {:error,
           {:daemon_unavailable,
            "spawned daemon at #{sock_path} did not complete the handshake within " <>
              "#{div(spawn_wait(opts), 1_000)}s (see #{Path.dirname(sock_path)}/daemon.log)"}}
        else
          Process.sleep(@poll_ms)
          await_handshake(sock_path, home, opts, deadline)
        end
    end
  end

  defp spawn_wait(opts), do: Keyword.get(opts, :spawn_wait_ms, @spawn_wait_ms)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
