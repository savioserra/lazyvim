defmodule Workstation.Daemon.Protocol do
  @moduledoc """
  Daemon wire protocol: framing, JSON codec and strict request schemas.

  Frame layout: a 4-byte unsigned big-endian length prefix followed by exactly
  that many bytes of UTF-8 JSON. Length-prefixed framing keeps one connection
  from streaming an unbounded body under a parser, so every size is checked
  against a hard cap before decode. Request envelopes are Zoi-validated and
  rejected by default: anything that is not explicitly allowed fails closed.

  Wire concerns only. The served operation set and their param schemas live
  with the domain capabilities (see `Workstation.Daemon.Capability` and the
  `Workstation.Daemon.Capabilities` registry); protocol.ex has no per-op
  knowledge.
  """

  alias Workstation.Daemon.Capabilities

  @protocol_name "workstation.daemon/1"
  @version 1

  # Frame budget. Requests are tiny JSON envelopes; responses carry rendered
  # plans and are allowed to be considerably larger but never unbounded.
  @header_bytes 4
  @max_request_bytes 1_048_576
  @max_response_bytes 16_777_216
  @frame_timeout_ms 5_000
  @max_depth 32

  @typedoc "A rejected request: {error_code, human message}"
  @type decode_error :: {String.t(), String.t()}

  @typedoc "A decoded request envelope: id, op and validated params"
  @type request :: %{String.t() => term()}

  @request_schema Zoi.object(
                    %{
                      "v" => Zoi.literal(1),
                      "id" => Zoi.union([Zoi.string(), Zoi.integer()]),
                      "op" => Zoi.string(),
                      "params" => Zoi.optional(Zoi.map())
                    },
                    unrecognized_keys: :error
                  )

  @hello_params_schema Zoi.object(%{"protocol" => Zoi.string()},
                        unrecognized_keys: :error
                      )

  @doc "Handshake identity line the client must match exactly."
  @spec protocol_name() :: String.t()
  def protocol_name, do: @protocol_name

  @doc "Wire envelope version."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Maximum request length in bytes (frame body)."
  @spec max_request_bytes() :: pos_integer()
  def max_request_bytes, do: @max_request_bytes

  @doc "Maximum response length in bytes (frame body)."
  @spec max_response_bytes() :: pos_integer()
  def max_response_bytes, do: @max_response_bytes

  @doc "How long a single frame read may take, in milliseconds."
  @spec frame_timeout_ms() :: pos_integer()
  def frame_timeout_ms, do: @frame_timeout_ms

  @doc "Bytes in the length prefix."
  @spec header_length() :: pos_integer()
  def header_length, do: @header_bytes

  @doc "Maximum JSON nesting depth accepted on decode."
  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  @doc """
  The hello handshake payload: protocol identity, version, served ops,
  registered domains and transport caps. Ops are the handshake op plus every
  capability op (sorted); domains derive from the capability registry.
  """
  @spec capabilities() :: map()
  def capabilities do
    %{
      "protocol" => @protocol_name,
      "version" => @version,
      "ops" => ops(),
      "domains" => Capabilities.domains(),
      "caps" => %{
        "max_request_bytes" => @max_request_bytes,
        "max_response_bytes" => @max_response_bytes,
        "frame_timeout_ms" => @frame_timeout_ms,
        "max_depth" => @max_depth
      }
    }
  end

  @doc "Advertised op names: the handshake plus every capability op, sorted."
  @spec ops() :: [String.t()]
  def ops, do: Enum.sort(["hello" | Capabilities.ops()])

  @doc """
  Encode one outbound frame: length prefix plus JSON body.

  Raises when the body exceeds the request cap; responses use
  `encode_result/2` and encode oversize as a protocol error instead.
  """
  @spec encode_frame(term()) :: iodata()
  def encode_frame(payload) do
    # Pre-encoded bodies (raw strings) pass through untouched; terms are
    # JSON-encoded once here so callers never double-encode.
    body = if is_binary(payload), do: payload, else: Jason.encode!(payload)
    size = byte_size(body)

    if size > @max_request_bytes do
      raise ArgumentError,
            "daemon frame of #{size} bytes exceeds the #{@max_request_bytes} byte cap"
    end

    <<size::unsigned-big-integer-size(@header_bytes * 8), body::binary>>
  end

  @doc """
  Frame header sanity: non-zero and within the request cap.

  Accepts the raw header bytes as read from the wire, or the already-decoded
  integer. A header outside these bounds means the peer is not speaking this
  protocol; the connection is dropped before any body is read.
  """
  @spec header_length_ok?(binary() | :eof | {:error, term()} | non_neg_integer()) :: boolean()
  def header_length_ok?(length)
      when is_integer(length) and length > 0 and length <= @max_request_bytes,
      do: true

  def header_length_ok?(<<length::unsigned-big-integer-size(@header_bytes * 8)>>),
    do: header_length_ok?(length)

  def header_length_ok?(_other), do: false

  @doc """
  Decode and validate one request envelope.

  Fails closed: unknown JSON, excessive depth, unexpected envelope fields,
  unknown ops and schema-invalid params all produce protocol errors.
  """
  @spec decode_request(binary()) :: {:ok, request()} | {:error, decode_error()}
  def decode_request(body) do
    with {:ok, decoded} <- jason_decode(body),
         {:ok, _request} <- depth_ok?(decoded, @max_depth),
         {:ok, request} <- schema_decode(@request_schema, decoded, "bad_request"),
         :ok <- known_op?(request),
         {:ok, request} <- attach_params(request) do
      {:ok, request}
    end
  end

  @doc "Decode hello handshake params (strict)."
  @spec decode_hello_params(term()) :: {:ok, map()} | {:error, decode_error()}
  def decode_hello_params(params) do
    schema_decode(@hello_params_schema, params, "invalid_params")
  end

  @doc """
  True when the announced handshake does not match this daemon's protocol.
  An empty params map is tolerated for pre-handshake probes.
  """
  @spec version_mismatch?(term()) :: boolean()
  def version_mismatch?(%{"protocol" => protocol}), do: protocol != @protocol_name
  def version_mismatch?(_other), do: false

  @doc """
  Decode params for any served op against its capability schema.

  Hello params are optional at the envelope level (an absent map decodes as
  empty and fails the handshake schema on the missing protocol
  announcement); every other op requires a params object.
  """
  @spec decode_params(String.t(), term()) :: {:ok, map()} | {:error, decode_error()}
  def decode_params("hello", nil), do: decode_hello_params(%{})
  def decode_params("hello", params), do: decode_hello_params(params)

  def decode_params(op, nil),
    do: {:error, {"invalid_params", "#{op} requires params"}}

  def decode_params(op, params) do
    case Capabilities.schema(op) do
      {:ok, schema} -> schema_decode(schema, params, "invalid_params")
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Encode a successful op result as a frame, or a protocol error when the
  response exceeds the response cap. `id` echoes the request id.
  """
  @spec encode_result(term(), term()) ::
          {:ok, iodata()} | {:error, {:response_too_large, pos_integer()}}
  def encode_result(id, payload) do
    body = Jason.encode!(%{"id" => id, "ok" => true, "result" => payload})
    size = byte_size(body)

    if size > @max_response_bytes do
      {:error, {:response_too_large, size}}
    else
      {:ok, <<size::unsigned-big-integer-size(@header_bytes * 8), body::binary>>}
    end
  end

  @doc """
  Encode a protocol error frame: `ok: false` with `{code, message}`.
  """
  @spec encode_error(term(), String.t(), String.t()) :: iodata()
  def encode_error(id, code, message) do
    body =
      Jason.encode!(%{"id" => id, "ok" => false, "error" => %{"code" => code, "message" => message}})

    <<byte_size(body)::unsigned-big-integer-size(@header_bytes * 8), body::binary>>
  end

  @doc "Protocol error code for ops outside the served set."
  @spec unknown_op() :: {String.t(), String.t()}
  def unknown_op, do: {"unknown_op", "op is not served by this daemon"}

  defp jason_decode(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, {"bad_json", "request body is not valid JSON"}}
    end
  end

  # Deeply nested JSON can drive recursive decoders through the stack, so
  # depth is bounded before any schema sees the value. Containers may occupy
  # depths 1..@max_depth; anything nested below a depth-0 container violates.
  # The walk itself is boolean so Enum.all?/2 short-circuits on the first
  # violation.
  defp depth_ok?(value, depth), do: if(depth_ok(value, depth), do: {:ok, value}, else: nesting_error())

  defp depth_ok(_value, depth) when depth < 0, do: false

  defp depth_ok(%{} = value, depth), do: Enum.all?(Map.values(value), &depth_ok(&1, depth - 1))

  defp depth_ok(list, depth) when is_list(list), do: Enum.all?(list, &depth_ok(&1, depth - 1))

  defp depth_ok(_scalar, _depth), do: true

  defp nesting_error,
    do: {:error, {"bad_request", "request nesting exceeds #{@max_depth} levels"}}

  defp schema_decode(schema, value, code) do
    case Zoi.parse(schema, value) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, errors} -> {:error, {code, render_errors(errors)}}
    end
  end

  defp render_errors(errors) when is_list(errors) do
    Enum.map_join(errors, "; ", fn
      %{path: path, message: message} -> "#{Enum.join(path, ".")}: #{message}"
      %{message: message} -> message
      message when is_binary(message) -> message
    end)
  end

  defp known_op?(%{"op" => op}) do
    if op in ops(), do: :ok, else: {:error, unknown_op()}
  end

  defp attach_params(%{"op" => op} = request) do
    params =
      case Map.fetch(request, "params") do
        {:ok, params} when is_map(params) -> params
        _other -> nil
      end

    case decode_params(op, params) do
      {:ok, decoded} -> {:ok, Map.put(request, "params", decoded)}
      {:error, reason} -> {:error, reason}
    end
  end
end
