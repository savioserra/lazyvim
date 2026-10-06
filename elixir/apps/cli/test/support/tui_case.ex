defmodule Workstation.CLITest.TUI do
  @moduledoc false

  # Shared DeterministicBackend harness for the TUI screen tests (spike
  # contract, /tmp/fleet/spikes/term_ui.md):
  #
  #   * backend `:size` is `{rows, columns}` while the app sees
  #     `{width, height}` — this harness takes screen-shaped `:cols`/`:rows`
  #     opts and flips them once;
  #   * printables arrive as `TermUI.Event.Text`, arrows also as glyphs;
  #   * `render_interval: 1` so timer-driven state resolves quickly;
  #   * all timers resolve through the app's `update/2`;
  # Frames are 1-based (row_text/2, cell/3), Layout rects 0-based. Flush
  # messages carry no frame; collect_last consumes them so repeated drains
  # do not starve on a mailbox full of quiet-period flushes.
  #
  # Screens run under the test supervisor via an explicit child spec so a
  # failing test cannot leak a runtime that owns the draw mailbox.

  alias TermUI.Event
  alias TermUI.Test.DeterministicBackend

  import ExUnit.Assertions

  @receive_timeout 2_000
  @quiet_ms 100
  @settle_timeout_ms 5_000

  @doc "Starts a screen on the deterministic backend and returns the runtime pid."
  def start_screen!(module, opts \\ []) do
    rows = Keyword.get(opts, :rows, 12)
    cols = Keyword.get(opts, :cols, 64)
    screen_opts = Keyword.get(opts, :screen_opts, [])

    runtime_opts =
      [
        backend:
          {DeterministicBackend,
           owner: self(), size: {rows, cols}, capabilities: %{colors: :ansi_16, unicode: true}},
        render_interval: 1
      ]
      |> Keyword.merge(screen_opts)

    spec = %{id: {module, make_ref()}, start: {TermUI, :start_link, [module, runtime_opts]}}
    ExUnit.Callbacks.start_supervised!(spec)
  end

  @doc "Sends one event to the runtime (printables via Event.Text)."
  def send_event(runtime, event), do: DeterministicBackend.send_event(runtime, event)

  def send_text(runtime, text), do: send_event(runtime, Event.text(text))
  def send_key(runtime, key), do: send_event(runtime, Event.key(key))

  @doc """
  Drains draw messages until the mailbox is quiet for `@quiet_ms` and
  returns the LAST frame. A drain swallows every redraw in its quiet
  window — including toast-expiry redraws shorter than `@quiet_ms`. To
  assert a post-expiry frame, force a deterministic redraw afterwards
  (e.g. send an Event.Resize) and drain again.
  """
  @spec latest_frame() :: TermUI.Frame.t()
  def latest_frame do
    assert_receive {:backend, :draw, %TermUI.Frame{} = first}, @receive_timeout
    collect_last(first)
  end

  defp collect_last(latest) do
    receive do
      {:backend, :draw, %TermUI.Frame{} = frame} -> collect_last(frame)
      {:backend, :flush, _count} -> collect_last(latest)
    after
      @quiet_ms -> latest
    end
  end

  @doc """
  Waits — bounded — for a frame whose body satisfies `predicate`, riding
  async wire loads to completion. A single `latest_frame/0` drain can go
  quiet before a slow loader/executor answer lands and then read the
  in-flight frame as settled (the shell_test embedded-apply flake): this
  helper drains the in-flight burst, then keeps consuming draw frames —
  every load completion delivers `{:wire_loaded, ...}` and redraws through
  the app's `update/2` — until one matches, or `:timeout_ms` (default
  #{@settle_timeout_ms}) is spent. Returns the matching frame; flunks on
  timeout, so a missed state is a bounded, self-describing failure, never
  a hang.
  """
  @spec await_frame((TermUI.Frame.t() -> boolean()), keyword()) :: TermUI.Frame.t()
  def await_frame(predicate, opts \\ []) when is_function(predicate, 1) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @settle_timeout_ms)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    # The in-flight burst first: the matching frame may already be the
    # settled one, with nothing further in flight.
    frame = latest_frame()
    if predicate.(frame), do: frame, else: await_match(predicate, deadline)
  end

  defp await_match(predicate, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:backend, :draw, %TermUI.Frame{} = frame} ->
        if predicate.(frame), do: frame, else: await_match(predicate, deadline)

      {:backend, :flush, _count} ->
        await_match(predicate, deadline)
    after
      remaining ->
        flunk("await_frame: no frame matched the predicate within the settle budget")
    end
  end

  @doc "Waits for the runtime to stop and returns the backend snapshot."
  def shutdown_snapshot do
    assert_receive {:backend, :shutdown_snapshot, snapshot}, @receive_timeout
    snapshot
  end
end
