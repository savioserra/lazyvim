defmodule Workstation.CLI.TUI.Executor do
  @moduledoc """
  The daemon-orchestrated executors behind the apply and update screens
  (the b8 graduation wiring).

  The screens own interaction only; the executor is the mutation seam they
  invoke on confirm. This module is that seam's production answer: it speaks
  the daemon frame protocol (`Workstation.Daemon.Protocol`) over the
  destination home's socket — hello handshake, then one lifecycle op per
  run — so every apply-shaped mutation request is serialized through the
  daemon's orchestrator lock, exactly the path the Lua one-shot apply uses.

  Fail-closed in both directions: any socket, timeout, protocol, or
  daemon-refusal failure becomes `{:error, reason}` — never `:ok`. Until the
  engine applier graduates (b8 gate), the daemon answers `not_graduated`, so
  the screens can only ever show an honest error today. The wiring itself
  (socket, handshake, op surface, error shape) is the graduation contract
  and does not churn when the applier lands: only the daemon's refusal body
  changes.

  Socket discipline mirrors `Workstation.CLI.TUI.Theme`: short budgets (the
  daemon's own frame timeout is 5s; a client that waits that long makes the
  TUI feel hung), every failure folded into one refusal shape, and no atom
  is ever minted from a hostile peer's strings (error codes stay binaries).
  """

  alias Workstation.Daemon.{Listener, Protocol}

  @connect_timeout_ms 1_000
  @recv_timeout_ms 2_000

  @type reason ::
          :daemon_unavailable
          | {:daemon, code :: String.t(), message :: String.t()}

  @doc """
  Apply executor: the confirm path of the apply screen. The payload is the
  screen's request map (generation + entry rows); the daemon refuses until
  the applier graduates, so `:ok` is unreachable today by construction.
  """
  @spec apply_executor(map()) :: :ok | {:error, reason()}
  def apply_executor(%{"generation" => generation, "entries" => entries})
      when is_binary(generation) and is_list(entries) do
    run_op("apply.run", %{"generation" => generation, "entries" => entries})
  end

  def apply_executor(_payload), do: {:error, :daemon_unavailable}

  @doc """
  Update executor: one lifecycle step per request (the update screen's
  abort-on-first-failure semantics map one op onto one chain link).
  """
  @spec update_executor(map()) :: :ok | {:error, reason()}
  def update_executor(%{"step" => step}) when is_binary(step) do
    run_op("update.run", %{"step" => step})
  end

  def update_executor(_payload), do: {:error, :daemon_unavailable}

  ## socket path

  defp run_op(op, params) do
    home = Workstation.Core.EngineState.home()
    sock_path = Listener.socket_path(home)

    if File.exists?(sock_path) do
      request(sock_path, op, params)
    else
      # No daemon serving this home: refuse rather than mutating outside the
      # orchestration lock — a lockless apply would race the Lua one-shot.
      {:error, :daemon_unavailable}
    end
  end

  defp request(sock_path, op, params) do
    case :socket.open(:local, :stream, :default) do
      {:ok, sock} ->
        try do
          with :ok <-
                 :socket.connect(
                   sock,
                   %{family: :local, path: String.to_charlist(sock_path)},
                   @connect_timeout_ms
                 ),
               {:ok, hello} <- roundtrip(sock, request_frame("hello", %{"protocol" => Protocol.protocol_name()})),
               :ok <- hello_ok?(hello),
               {:ok, reply} <- roundtrip(sock, request_frame(op, params)) do
            verdict(reply)
          else
            _failure -> {:error, :daemon_unavailable}
          end
        rescue
          _error -> {:error, :daemon_unavailable}
        after
          :socket.close(sock)
        end

      {:error, _reason} ->
        {:error, :daemon_unavailable}
    end
  end

  defp roundtrip(sock, body) do
    with :ok <- :socket.send(sock, Protocol.encode_frame(body)) do
      case :socket.recv(sock, Protocol.header_length(), @recv_timeout_ms) do
        {:ok, <<length::unsigned-big-integer-size(32)>>} -> recv_exact(sock, length, [])
        {:ok, _partial} -> {:error, :short_header}
        {:error, _reason} = error -> error
      end
    end
  end

  defp recv_exact(_sock, 0, chunks) do
    # A malformed body is a protocol mismatch, folded into :daemon_unavailable
    # like every other failure — the screens render a reason, never a crash.
    case Jason.decode(IO.iodata_to_binary(Enum.reverse(chunks))) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :bad_reply}
    end
  end

  defp recv_exact(sock, remaining, chunks) do
    case :socket.recv(sock, remaining, @recv_timeout_ms) do
      {:ok, data} -> recv_exact(sock, remaining - byte_size(data), [data | chunks])
      {:error, _reason} = error -> error
    end
  end

  defp hello_ok?(%{"ok" => true, "result" => %{"protocol" => protocol}}),
    do: if(protocol == Protocol.protocol_name(), do: :ok, else: {:error, :protocol_mismatch})

  defp hello_ok?(_other), do: {:error, :protocol_mismatch}

  # The TUI side has two copies of this plumbing (executor/theme); their
  # wire-failure vocabulary is deliberately identical ({:error,
  # :protocol_mismatch} on hello mismatch, {:error, :bad_reply} on malformed
  # bodies) — theme.ex pins the same shapes, so a protocol change must be
  # made in both or the seam gets extracted.

  # Daemon verdicts: an ok answer is :ok (unreachable while the daemon
  # refuses mutation); every error frame keeps its code/message as binaries.
  # Codes are never atomized: the peer controls this string.
  defp verdict(%{"ok" => true}), do: :ok

  defp verdict(%{"ok" => false, "error" => %{"code" => code, "message" => message}})
       when is_binary(code) and is_binary(message) do
    {:error, {:daemon, code, message}}
  end

  defp verdict(_other), do: {:error, :bad_reply}

  defp request_frame(op, params),
    do:
      Jason.encode!(%{
        "v" => Protocol.version(),
        "id" => "tui-#{op}",
        "op" => op,
        "params" => params
      })
end
