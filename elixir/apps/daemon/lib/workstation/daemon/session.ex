defmodule Workstation.Daemon.Session do
  # Declared before the moduledoc so the doc can interpolate the real budget.
  @idle_timeout_ms 300_000

  @moduledoc """
  One accepted client connection: SO_PEERCRED authentication, frame reading
  under the protocol budgets, op dispatch, one in-flight op.

  Authentication (app-level, never OTP distribution): the listener fetches
  the peer credential ONCE at accept time through
  `:socket.getopt_native(sock, {1, 17}, 12)` — Linux `SOL_SOCKET`/`SO_PEERCRED`
  returning `struct ucred`. The named `:peercred` option is typespec-declared
  but NOT implemented by the `:socket` NIF on the pinned OTP 28 (probed:
  `prim_socket:supports(options)` reports `{{socket,peercred}, false}`), so the
  documented native form is the only spelling that works. The struct decodes
  as three native-int32 fields `{pid, uid, gid}` — the AUTH FIELD IS THE
  SECOND one (`uid`); the first is the peer pid. The session refuses the
  connection unless that uid equals the uid owning the socket file, re-checked
  no-follow at session start (both checks failing closed on any error, short
  buffer or decode failure — an unauthenticated daemon is worse than no
  daemon, and on platforms without SO_PEERCRED every connection is refused).

  Budgets: between frames the session idles for the idle budget (300s) before
  shutting down (reset on every completed op); once a frame's first byte has
  arrived, the whole frame must finish within the protocol's
  `frame_timeout_ms`. Ops are served one at a time by this very process, so
  "one in-flight op" is structural, and params never reach logs or events.
  """

  use GenServer

  require Logger

  alias Workstation.Core.EngineState
  alias Workstation.Daemon.{Capabilities, CapabilityRegistry, EventBus, Protocol}

  @enforce_keys [:sock, :sock_path, :peer_uid]
  defstruct [:sock, :sock_path, :peer_uid]

  # --- credential decoding -------------------------------------------------

  # The ucred decoder lives in ONE place: `Workstation.Daemon.Listener.ucred_uid/1`,
  # which owns the accept-time `getopt_native` call and is unit-pinned
  # (signed native-int32 layout, sentinel-refusing) in listener_test.exs. A
  # second session-side copy previously drifted to unsigned decoding — where
  # the pre-connection sentinel {pid=0, uid=-1, gid=-1} silently decoded as a
  # "valid" 4294967295 — so the session receives `peer_uid` from the listener
  # hand-off and never re-decodes credentials itself.

  @doc """
  The authentication decision: the peer's credential uid must equal the uid
  owning the socket file, checked no-follow (a symlinked socket path is a
  redirect attempt, never followed).
  """
  @spec authorize?(term(), non_neg_integer(), String.t()) :: boolean()
  def authorize?(:invalid, _owner, _path), do: false

  def authorize?(peer_uid, owner_uid, path) when is_integer(peer_uid) do
    case EngineState.lstat(path) do
      %{type: type, uid: ^owner_uid} -> type != "link" and peer_uid == owner_uid
      _other -> false
    end
  end

  def authorize?(_peer, _owner, _path), do: false

  # --- lifecycle -----------------------------------------------------------

  @doc false
  def child_spec(opts) do
    # Temporary: a dead session's socket dies with it; a restart would race a
    # fresh session for the same fd.
    %{id: {__MODULE__, make_ref()}, start: {__MODULE__, :start_link, [opts]}, restart: :temporary, type: :worker}
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, Map.new(opts), name: Keyword.get(opts, :name))
  end

  @impl true
  def init(state) do
    # Auth before anything is served; the listener flips control to this
    # process and then sends :begin.
    {:ok, state}
  end

  @impl true
  def handle_info(:begin, state) do
    owner_uid = EngineState.uid()

    if authorize?(state.peer_uid, owner_uid, state.sock_path) do
      EventBus.publish(:session, {:session_opened, state.peer_uid})
      serve(state)
    else
      # No protocol reply: an unauthenticated peer learns only that the
      # connection went away.
      EventBus.publish(:session, {:session_refused, state.peer_uid})
      close_and_stop(state)
    end
  end

  ## Frame loop ---------------------------------------------------------------

  # Waiting for a frame: the idle budget governs; receiving the header starts
  # the (much tighter) frame budget. A completed op loops back here, which is
  # exactly "idle timeout reset on any op".
  defp serve(state) do
    case read_exact(state.sock, Protocol.header_length(), @idle_timeout_ms) do
      {:ok, header} ->
        <<length::unsigned-big-integer-size(32)>> = header

        if Protocol.header_length_ok?(length) do
          case read_exact(state.sock, length, Protocol.frame_timeout_ms()) do
            {:ok, body} ->
              case handle_frame(body, state) do
                {:stop, _, _} = stop -> stop
                new_state -> serve(new_state)
              end

            {:error, _reason} ->
              close_and_stop(state)
          end
        else
          # A length outside the cap is refused with a protocol error so a
          # sane client can adapt, then the connection is closed: there is no
          # way to resync a length-prefixed stream after a bad header.
          reply(state, nil, {"bad_frame", "request length outside the protocol cap"})
          close_and_stop(state)
        end

      {:error, :timeout} ->
        close_and_stop(state)

      {:error, _reason} ->
        close_and_stop(state)
    end
  end

  defp handle_frame(body, state) do
    case Protocol.decode_request(body) do
      {:ok, request} ->
        dispatch(request, state)

      {:error, {code, message}} ->
        # Validation errors carry the id when it survived decoding well
        # enough to echo; framing/JSON errors have no id at all.
        reply(state, request_id(body), {code, message})
        EventBus.publish(:op, {:op_rejected, code})
        state
    end
  end

  defp dispatch(%{"id" => id, "op" => op} = request, state) do
    result =
      try do
        dispatch_op(op, request["params"])
      rescue
        exception ->
          # Fail the op, never the session; the client sees a protocol error,
          # the log sees the reason without params.
          Logger.error("daemon op failed op=#{op} reason=#{Exception.message(exception) || inspect(exception)}")

          {"internal", "internal daemon error"}
      end

    case result do
      {:mismatch} ->
        EventBus.publish(:op, {:op_rejected, "version_mismatch"})
        {:stop, :normal, state}

      {:ok, payload} ->
        reply(state, id, payload)
        EventBus.publish(:op, {:op_served, op})
        state

      {:error, {code, message}} ->
        reply(state, id, {code, message})
        EventBus.publish(:op, {:op_rejected, code})
        state
    end
  end

  # hello is the handshake branch (wire concern, not a capability op); every
  # served op dispatches through the one generic capability clause. Capabilities
  # covers unknown ops with the same protocol refusal the old per-op fallback
  # produced.
  defp dispatch_op("hello", params) do
    if Protocol.version_mismatch?(params) do
      # Version mismatch closes without a reply: the peer expects a different
      # daemon generation, so no frame we send could be meaningful to it.
      {:mismatch}
    else
      {:ok, CapabilityRegistry.capabilities()}
    end
  end

  defp dispatch_op(op, params), do: Capabilities.dispatch(op, params, self())

  defp reply(state, id, {code, message}) when is_binary(code) and is_binary(message),
    do: emit(state, Protocol.encode_error(id, code, message))

  defp reply(state, id, result) when is_map(result) do
    case Protocol.encode_result(id, result) do
      {:ok, frame} ->
        emit(state, frame)

      {:error, {:response_too_large, bytes}} ->
        emit(state, Protocol.encode_error(id, "response_too_large", "response exceeds the protocol cap (#{bytes} bytes)"))
    end
  end

  defp emit(state, frame) when is_binary(frame) do
    # Match, never assert: a peer that vanished between reading its frame and
    # this write must take the graceful close path (the next read of the dead
    # socket ends the loop and close_and_stop/1 publishes {:session_closed}),
    # not crash this session and skip the event.
    case :socket.send(state.sock, frame) do
      :ok -> state
      {:error, _reason} -> state
    end
  end

  # Best-effort id echo for decode failures: only when the body parses AND
  # carries a shape-valid id.
  defp request_id(body) do
    with {:ok, %{"id" => id}} <- Jason.decode(body),
         true <- is_binary(id) or is_integer(id) do
      id
    else
      _ -> nil
    end
  end

  # Exact-N reads: :socket.recv may return fewer bytes than asked, so the
  # buffer accumulates until N bytes or the deadline (single budget across
  # the chunked reads, computed once per frame phase).
  defp read_exact(sock, wanted, budget) do
    do_read_exact(sock, wanted, [], now_ms() + budget)
  end

  defp do_read_exact(_sock, 0, chunks, _deadline), do: {:ok, IO.iodata_to_binary(Enum.reverse(chunks))}

  defp do_read_exact(sock, remaining, chunks, deadline) do
    if now_ms() >= deadline do
      {:error, :timeout}
    else
      case :socket.recv(sock, remaining, deadline - now_ms()) do
        {:ok, <<>>} -> {:error, :closed}
        {:ok, data} -> do_read_exact(sock, remaining - byte_size(data), [data | chunks], deadline)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp close_and_stop(state) do
    _ = :socket.close(state.sock)
    EventBus.publish(:session, {:session_closed, state.peer_uid})
    {:stop, :normal, state}
  end
end
