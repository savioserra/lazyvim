defmodule Workstation.CLI.TUI.Theme do
  @moduledoc """
  Palette resolution for the apply/update screens.

  docs/theme.md pins term_ui as a `palette`-layer consumer: it cannot follow
  the live terminal palette through OSC 4 retints, so the screens need
  concrete `#rrggbb` colors and never terminal slot names. Resolution order:

    1. the daemon overlay domain (`theme.resolve` over the destination
       home's daemon socket) — the authority while a daemon serves that
       home, because operator overlay state lives there;
    2. the base token palette (`Workstation.Core.Theme.Tokens.palette/1`,
       the mirror of `workstation/packages/theme/tokens.lua`) — the same
       bytes the daemon resolves from, so both paths agree while no overlay
       is configured.

  Fail-closed fallback: any socket, timeout, protocol, or shape failure
  answers with (2). A missing or wedged daemon may cost overlay freshness,
  never a broken screen — and the resolver never starts a daemon on demand:
  it answers within the socket budgets or falls back. Authentication is the
  daemon's own peercred check; the client adds nothing to it.

  Slot names are deliberately absent here: a palette-layer consumer would
  render them as literals, which is exactly the drift docs/theme.md forbids.
  """

  alias Workstation.Core.Theme.Tokens
  alias Workstation.Daemon.{Listener, Protocol}

  @default_appearance :dark

  # The closed palette role set (docs/theme.md): the six consumer roles, the
  # btop-grammar affordance roles (shortcut, selected pair, inactive, ramp
  # trio), the per-domain panel border roles and the palette-only bg/muted
  # pair. A daemon resolution carrying any other key is refused wholesale —
  # a partial theme is worse than the base one.
  @roles [:accent, :ok, :warn, :err, :chrome, :text, :shortcut, :selected_bg, :selected_fg, :inactive, :ramp_start, :ramp_mid, :ramp_end, :border_engine, :border_journal, :border_capabilities, :border_plan, :border_diff, :border_status, :bg, :muted]

  # Short budgets on purpose: screen startup must not wait on a wedged
  # daemon. The daemon's own frame timeout is 5s; a client that waits that
  # long before falling back would make the TUI feel hung.
  @connect_timeout_ms 1_000
  @recv_timeout_ms 2_000

  @type role ::
          :accent
          | :ok
          | :warn
          | :err
          | :chrome
          | :text
          | :shortcut
          | :selected_bg
          | :selected_fg
          | :inactive
          | :ramp_start
          | :ramp_mid
          | :ramp_end
          | :border_engine
          | :border_journal
          | :border_capabilities
          | :border_plan
          | :border_diff
          | :border_status
          | :bg
          | :muted
  @type colors :: %{optional(role()) => String.t()}
  @type resolution :: %{colors: colors(), source: :daemon | :base}

  @doc """
  Resolve one palette. Options:

    * `:home` — the destination home whose daemon socket is tried first;
      without it only the base path can answer.
    * `:appearance` — `:dark` (default) or `:light`; resolution never
      silently switches appearance (Overlay contract).
    * `:connect_timeout_ms` / `:recv_timeout_ms` — socket budgets.
  """
  @spec resolve(keyword()) :: resolution()
  def resolve(opts \\ []) do
    appearance = Keyword.get(opts, :appearance, @default_appearance)

    case daemon_colors(opts, appearance) do
      {:ok, colors} -> %{colors: colors, source: :daemon}
      :unavailable -> %{colors: base_colors(appearance), source: :base}
    end
  end

  @doc "Base token palette of one appearance, atom-keyed (the no-daemon answer)."
  @spec base_colors(atom() | String.t()) :: colors()
  def base_colors(appearance), do: Map.new(Tokens.palette(appearance))

  @doc """
  `#rrggbb` to a term_ui RGB style color; any other shape is nil so callers
  skip the tint instead of guessing.
  """
  @spec to_term_ui_color(term()) :: {:rgb, 0..255, 0..255, 0..255} | nil
  def to_term_ui_color("#" <> <<r::binary-size(2), g::binary-size(2), b::binary-size(2)>>) do
    with {{r, ""}, {g, ""}, {b, ""}} <-
           {Integer.parse(r, 16), Integer.parse(g, 16), Integer.parse(b, 16)} do
      {:rgb, r, g, b}
    else
      _ -> nil
    end
  end

  def to_term_ui_color(_other), do: nil

  ## daemon path

  defp daemon_colors(opts, appearance) do
    home = Keyword.get(opts, :home)

    if is_binary(home) do
      sock_path = Listener.socket_path(home)

      if File.exists?(sock_path) do
        request(sock_path, appearance, opts)
      else
        :unavailable
      end
    else
      :unavailable
    end
  end

  # Every failure mode — connect refused, timeout, protocol mismatch,
  # unexpected shape — collapses to one answer: the daemon is not usable
  # right now. Callers cannot distinguish (and must not care) why.
  defp request(sock_path, appearance, opts) do
    connect_timeout = Keyword.get(opts, :connect_timeout_ms, @connect_timeout_ms)
    recv_timeout = Keyword.get(opts, :recv_timeout_ms, @recv_timeout_ms)

    case :socket.open(:local, :stream, :default) do
      {:ok, sock} ->
        try do
          with :ok <-
                 :socket.connect(
                   sock,
                   %{family: :local, path: String.to_charlist(sock_path)},
                   connect_timeout
                 ),
               {:ok, hello} <- roundtrip(sock, hello_frame(), recv_timeout),
               :ok <- hello_ok?(hello),
               {:ok, reply} <- roundtrip(sock, theme_frame(appearance), recv_timeout) do
            parse_colors(reply)
          else
            _other -> :unavailable
          end
        rescue
          _error -> :unavailable
        after
          :socket.close(sock)
        end

      {:error, _reason} ->
        :unavailable
    end
  end

  defp roundtrip(sock, body, timeout) do
    with :ok <- :socket.send(sock, Protocol.encode_frame(body)) do
      case :socket.recv(sock, Protocol.header_length(), timeout) do
        {:ok, <<length::unsigned-big-integer-size(32)>>} -> recv_exact(sock, length, timeout, [])
        {:ok, _partial} -> {:error, :short_header}
        {:error, _reason} = error -> error
      end
    end
  end

  defp recv_exact(_sock, 0, _timeout, chunks) do
    # Decode here, with the executor's exact error shape: a malformed body is
    # a protocol mismatch ({:error, :bad_reply}); the fold into :unavailable
    # happens in request/3's catch-all, which is why this function must not
    # leak the raw %Jason.DecodeError{} to its caller.
    case Jason.decode(IO.iodata_to_binary(Enum.reverse(chunks))) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :bad_reply}
    end
  end

  defp recv_exact(sock, remaining, timeout, chunks) do
    case :socket.recv(sock, remaining, timeout) do
      {:ok, data} -> recv_exact(sock, remaining - byte_size(data), timeout, [data | chunks])
      {:error, _reason} = error -> error
    end
  end

  # Wire-failure shapes are pinned to the executor's vocabulary on purpose:
  # two copies of the same plumbing must not grow diverged error atoms for
  # identical failure modes (protocol mismatch here once returned a bare
  # :error, unmatchable by any caller of the executor-shaped API).
  defp hello_ok?(%{"ok" => true, "result" => %{"protocol" => protocol}}),
    do: if(protocol == Protocol.protocol_name(), do: :ok, else: {:error, :protocol_mismatch})

  defp hello_ok?(_other), do: {:error, :protocol_mismatch}

  # Strict shape: exactly the closed role set with binary values. The key
  # set is proven before to_existing_atom, so a hostile peer can never mint
  # atoms through this client.
  defp parse_colors(%{"ok" => true, "result" => %{"colors" => colors}}) when is_map(colors) do
    role_binaries = MapSet.new(@roles, &Atom.to_string/1)

    if MapSet.new(Map.keys(colors)) == role_binaries and
         Enum.all?(Map.values(colors), &is_binary/1) do
      {:ok, Map.new(colors, fn {role, hex} -> {String.to_existing_atom(role), hex} end)}
    else
      :unavailable
    end
  end

  defp parse_colors(_other), do: :unavailable

  defp hello_frame,
    do: request_frame("hello", %{"protocol" => Protocol.protocol_name()})

  defp theme_frame(appearance),
    do:
      request_frame("theme.resolve", %{
        "appearance" => Atom.to_string(appearance),
        "overlays" => []
      })

  defp request_frame(op, params),
    do:
      Jason.encode!(%{
        "v" => Protocol.version(),
        "id" => "tui-#{op}",
        "op" => op,
        "params" => params
      })
end
