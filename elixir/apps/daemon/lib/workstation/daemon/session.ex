defmodule Workstation.Daemon.Session do
  # Declared before the moduledoc so the doc can interpolate the real budget.
  @idle_timeout_ms 300_000
  # While an op is in flight the reader waits for the NEXT frame with a much
  # longer budget: a lifecycle chain can legitimately run for many minutes,
  # and killing the connection at the 300s idle mark would cut the event
  # stream mid-op. The op's own client-side budget governs the op itself.
  @op_idle_timeout_ms 3_600_000
  # The reader slices its budget so a budget retarget (op started/ended)
  # takes effect within one slice instead of after the current read.
  @budget_slice_ms 1_000

  @moduledoc """
  One accepted client connection: SO_PEERCRED authentication, frame reading
  under the protocol budgets, op dispatch, one in-flight op, and — the
  live-streaming half — progress-event forwarding while that op runs.

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

  Structure: a small READER process owns the blocking `recv` calls and
  forwards `{:frame, body}` messages, so the session's main loop can
  multiplex client frames, EventBus progress events, and op-task results.
  Ops dispatch ASYNC in a task under `Workstation.Daemon.TaskSupervisor`
  (one in-flight op per session — a second op frame mid-flight is refused
  with `op_in_flight`): the session subscribes to the EventBus `:op`
  topic, filters events to the in-flight `op_ref`, stamps a per-stream
  `seq`, and emits `{"event": ...}` frames while the op runs. The op task
  registers its abort target in `Workstation.Daemon.OpRegistry`, so an
  `op.abort` frame — even from another session — reaches it; the task
  honours the abort at its next step boundary.

  Detach semantics: a client that disconnects mid-op does NOT cancel the
  op. The task is not linked to the session; the daemon-side run survives
  and settles under its lock (a half-run mutation must never be abandoned
  by a vanished reader), and the registry-cleanup reaps the abort target.

  Budgets: between frames the reader idles for the idle budget (300s,
  sliced so retargets apply promptly); once a frame's first byte has
  arrived, the whole frame must finish within the protocol's
  `frame_timeout_ms`. While an op is in flight the between-frames budget
  stretches to #{@op_idle_timeout_ms} ms. Params never reach logs or events.
  """

  use GenServer

  require Logger

  alias Workstation.Core.EngineState
  alias Workstation.Daemon.{Capabilities, CapabilityRegistry, EventBus, Events, Protocol, TaskSupervisor}

  @enforce_keys [:sock, :sock_path, :peer_uid]
  defstruct [:sock, :sock_path, :peer_uid, :reader, inflight: nil, events: 0]

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
      # Trap exits: the reader is LINKED (its death is this session's death),
      # and the EXIT must arrive as a handled message, not a crash — a client
      # hangup is a graceful close, never an error log.
      Process.flag(:trap_exit, true)
      # The runtime state is the option map until now; the loop needs the
      # struct's loop bookkeeping (reader/inflight/seq counters).
      session = struct(__MODULE__, Map.to_list(state))
      reader = spawn_link(__MODULE__, :reader_main, [session.sock, @idle_timeout_ms, self()])
      loop(%{session | reader: reader})
    else
      # No protocol reply: an unauthenticated peer learns only that the
      # connection went away.
      EventBus.publish(:session, {:session_refused, state.peer_uid})
      close_and_stop(state)
    end
  end

  @doc false
  # The reader's main loop, spawned via spawn_link/3 (needs a public arity/3).
  # Blocks on recv (the socket is passive), forwards whole frames, and slices
  # the between-frames budget so a retarget takes effect within one slice.
  def reader_main(sock, budget_ms, owner) do
    case read_exact_budgeted(sock, Protocol.header_length(), budget_ms, owner) do
      {:ok, header} ->
        <<length::unsigned-big-integer-size(32)>> = header

        if Protocol.header_length_ok?(length) do
          case read_exact(sock, length, Protocol.frame_timeout_ms()) do
            {:ok, body} ->
              send(owner, {:frame, body})
              reader_main(sock, current_budget(owner, budget_ms), owner)

            {:error, :timeout} ->
              send(owner, {:reader, :timeout})

            {:error, _reason} ->
              send(owner, {:reader, :closed})
          end
        else
          # A length outside the cap cannot resync a length-prefixed stream.
          send(owner, {:reader, {:bad_length, length}})
        end

      {:error, :timeout} ->
        send(owner, {:reader, :timeout})

      {:error, _reason} ->
        send(owner, {:reader, :closed})
    end
  end

  # The reader asks the session for its CURRENT between-frames budget after
  # every frame, so the idle/op stretch switch cannot race the next read.
  defp current_budget(_owner, default) do
    receive do
      {:budget, ms} when is_integer(ms) and ms > 0 -> ms
    after
      0 -> default
    end
  end

  defp retarget_budget(reader, ms), do: send(reader, {:budget, ms})

  # Exact-N reads whose deadline can be RETARGETED mid-read: the reader polls
  # its mailbox for {:budget, ms} between slices and recomputes the deadline
  # from NOW. (Plain read_exact/3 below has a fixed budget — frame bodies
  # never need retargeting.)
  defp read_exact_budgeted(sock, wanted, budget_ms, owner) do
    do_read_budgeted(sock, wanted, [], now_ms() + budget_ms, owner)
  end

  defp do_read_budgeted(_sock, 0, chunks, _deadline, _owner),
    do: {:ok, IO.iodata_to_binary(Enum.reverse(chunks))}

  defp do_read_budgeted(sock, remaining, chunks, deadline, owner) do
    now = now_ms()

    if now >= deadline do
      {:error, :timeout}
    else
      slice = min(deadline - now, @budget_slice_ms)

      case :socket.recv(sock, remaining, slice) do
        {:ok, data} ->
          do_read_budgeted(sock, remaining - byte_size(data), [data | chunks], deadline, owner)

        {:error, :timeout} ->
          receive do
            {:budget, ms} when is_integer(ms) and ms > 0 ->
              do_read_budgeted(sock, remaining, chunks, now_ms() + ms, owner)
          after
            0 -> do_read_budgeted(sock, remaining, chunks, deadline, owner)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  ## main loop ---------------------------------------------------------------

  # Idle: no op in flight — frames dispatch, stray events are dropped.
  defp loop(%{inflight: nil} = state) do
    receive do
      {:frame, body} ->
        case handle_frame(body, state) do
          {:stop, _, _} = stop -> stop
          new_state -> loop(new_state)
        end

      {:daemon_event, :op, _stray} ->
        # A trailing event from an op that just settled (dispatch raced the
        # unsubscribe). Its stream is closed; nobody is owed this frame.
        loop(state)

      {:reader, {:bad_length, _length}} ->
        # A length outside the cap is refused with a protocol error so a
        # sane client can adapt, then the connection is closed: there is no
        # way to resync a length-prefixed stream after a bad header.
        reply(state, nil, {"bad_frame", "request length outside the protocol cap"})
        close_and_stop(state)

      {:reader, :closed} ->
        close_and_stop(state)

      {:reader, :timeout} ->
        close_and_stop(state)

      {:EXIT, reader, _reason} when reader == state.reader ->
        close_and_stop(state)
    end
  end

  # In-flight: forward matching events, accept aborts, refuse second ops,
  # and settle on the op task's result.
  defp loop(%{inflight: %{op_ref: op_ref}} = state) do
    receive do
      {:frame, body} ->
        case handle_frame_inflight(body, state) do
          {:stop, _, _} = stop -> stop
          new_state -> loop(new_state)
        end

      {:daemon_event, :op, %{"op_ref" => ^op_ref} = event} ->
        seq = state.events + 1

        case Protocol.encode_event(Map.put(event, "seq", seq)) do
          {:ok, frame} ->
            emit(state, frame)
            loop(%{state | events: seq})

          {:error, {:response_too_large, _bytes}} ->
            # Events are bounded by construction (identifiers and step
            # names, never payloads); a cap breach is dropped, never fatal.
            loop(%{state | events: seq})
        end

      {:daemon_event, :op, _other_op} ->
        # Another session's op — the session filter is what keeps one
        # client's stream free of another's progress.
        loop(state)

      {:op_done, ^op_ref, result} ->
        finish_op(state, result)

      {:reader, {:bad_length, _length}} ->
        reply(state, nil, {"bad_frame", "request length outside the protocol cap"})
        close_and_stop(state)

      {:reader, :closed} ->
        detach_close(state)

      {:reader, :timeout} ->
        detach_close(state)

      {:EXIT, reader, _reason} when reader == state.reader ->
        detach_close(state)
    end
  end

  ## frames ------------------------------------------------------------------

  # Waiting for a frame: the idle budget governs (handled by the reader). A
  # completed op loops back here, which is exactly "idle timeout reset on
  # any op".
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

  # A frame while an op is in flight: aborts pass through, everything else
  # is refused — one in-flight op per session stays structural.
  defp handle_frame_inflight(body, state) do
    case Protocol.decode_request(body) do
      {:ok, %{"op" => "op.abort"} = request} ->
        abort_frame(request, state)

      {:ok, request} ->
        reply(state, request["id"], {"op_in_flight", "an op is already running on this session"})
        EventBus.publish(:op, {:op_rejected, "op_in_flight"})
        state

      {:error, {code, message}} ->
        reply(state, request_id(body), {code, message})
        EventBus.publish(:op, {:op_rejected, code})
        state
    end
  end

  # op.abort is session plumbing, not a capability op: it targets an op
  # STREAM, and its honest idle answer is %{"aborted" => false}. A present
  # but ill-typed op_ref is a params violation, never a silent no-op.
  defp abort_frame(request, state) do
    params = request["params"] || %{}
    op_ref = params["op_ref"]

    cond do
      not Map.has_key?(params, "op_ref") ->
        reply(state, request["id"], {:ok, %{"aborted" => false}})

      is_binary(op_ref) ->
        reply(state, request["id"], {:ok, %{"aborted" => Events.abort(op_ref)}})

      true ->
        reply(state, request["id"], {"invalid_params", "op.abort params.op_ref must be a string"})
    end

    state
  end

  defp dispatch(%{"id" => id, "op" => op} = request, state) do
    cond do
      op == "hello" ->
        dispatch_hello(id, request["params"], state)

      op == "op.abort" ->
        abort_frame(%{"id" => id, "op" => op, "params" => request["params"]}, state)
        EventBus.publish(:op, {:op_served, op})
        state

      true ->
        start_op(request, state)
    end
  end

  defp dispatch_hello(id, params, state) do
    if Protocol.version_mismatch?(params) do
      # Version mismatch closes without a reply: the peer expects a different
      # daemon generation, so no frame we send could be meaningful to it.
      EventBus.publish(:op, {:op_rejected, "version_mismatch"})
      {:stop, :normal, state}
    else
      reply(state, id, CapabilityRegistry.capabilities())
      EventBus.publish(:op, {:op_served, "hello"})
      state
    end
  end

  # Async dispatch: subscribe BEFORE the task exists (no event can be lost),
  # spawn the task nolink (a disconnect must not kill the run), and keep the
  # in-flight bookkeeping the event filter and the settle path need.
  defp start_op(request, state) do
    %{"id" => id, "op" => op} = request
    params = request["params"]
    session = self()
    op_ref = Events.new_ref()

    :ok = EventBus.subscribe(:op)

    {:ok, task_pid} =
      Task.Supervisor.start_child(TaskSupervisor, fn ->
        :ok = Events.register(op_ref)

        result =
          try do
            Capabilities.dispatch(op, params, %{session: session, op_ref: op_ref})
          rescue
            exception ->
              # Fail the op, never the session; the client sees a protocol
              # error, the log sees the reason without params.
              Logger.error(
                "daemon op failed op=#{op} reason=#{Exception.message(exception) || inspect(exception)}"
              )

              {:error, {"internal", "internal daemon error"}}
          catch
            kind, value ->
              Logger.error("daemon op failed op=#{op} reason=#{inspect(kind)}:#{inspect(value)}")
              {:error, {"internal", "internal daemon error"}}
          end

        :ok = Events.unregister(op_ref)
        send(session, {:op_done, op_ref, result})
        result
      end)

    retarget_budget(state.reader, @op_idle_timeout_ms)

    loop(%{
      state
      | inflight: %{id: id, op: op, op_ref: op_ref, task: task_pid},
        events: 0
    })
  end

  defp finish_op(%{inflight: %{op: op}} = state, result) do
    EventBus.unsubscribe(:op)
    retarget_budget(state.reader, @idle_timeout_ms)

    case result do
      {:ok, payload} ->
        reply(state, state.inflight.id, payload)
        EventBus.publish(:op, {:op_served, op})

      {:error, {code, message}} ->
        reply(state, state.inflight.id, {code, message})
        EventBus.publish(:op, {:op_rejected, code})
    end

    loop(%{state | inflight: nil, events: 0})
  end

  # The reader died while an op ran: the client is gone, but the op task is
  # NOT linked to this session — it survives under the task supervisor and
  # settles under its lock (detach contract). Its late {:op_done} lands in
  # a dead mailbox, which is a no-op.
  defp detach_close(state), do: close_and_stop(state)

  defp reply(state, id, {code, message}) when is_binary(code) and is_binary(message),
    do: emit(state, Protocol.encode_error(id, code, message))

  defp reply(state, id, result) when is_map(result), do: reply(state, id, {:ok, result})

  defp reply(state, id, {:ok, result}) when is_map(result) do
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
