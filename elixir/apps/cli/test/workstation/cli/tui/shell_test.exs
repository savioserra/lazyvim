defmodule Workstation.CLI.TUI.ShellTest.MouseProbeScreen do
  @moduledoc false

  # Fails during init so `TUI.run/2` returns an error without entering the
  # render loop: the mouse-bracket assertions only need the byte order
  # around a guaranteed failure.
  def init(_opts), do: raise("mouse probe: guaranteed init failure")
end

defmodule Workstation.CLI.TUI.ShellTest do
  # The shell runs under the same DeterministicBackend harness as the
  # apply/update screen tests: a real TermUI runtime, fixed `:load` /
  # `:check` / executor seams (no daemon, deterministic replay), frames
  # asserted row-by-row. Wire fixtures use the production shapes — the
  # status wire carries the package→foundation `taxonomy` map, plan
  # entries carry `attribution`, and the update.check verdict is
  # `{"status" => "behind", "local" => …, "remote" => …}`.
  #
  # The app is ONE six-box dashboard: digits 1-6 toggle boxes, p/P cycles
  # presets, ? is a paged help overlay. The default harness size (100
  # cols) is below the 110-col slot-mosaic floor, so the default frames
  # exercise the priority stack; `start_shell_wide/1` (130 cols) exercises
  # the slot mosaic.
  use ExUnit.Case, async: true

  import Workstation.CLITest.TUI

  alias TermUI.{Event, Frame, Test.DeterministicBackend}
  alias Workstation.CLI.TUI.{Shell, Theme}

  @destination "/tmp/workstation-tui-shell-test-home"

  # -- fixtures: canned wires in the production entry-view shapes ----------

  defp status_wire do
    %{
      "destination" => @destination,
      "platform" => "linux-test",
      "engine" => %{"name" => "workstation", "version" => "9.9.9-test", "mode" => "test"},
      "taxonomy" => %{
        "nvim" => "foundation/editor",
        "helix" => "foundation/editor",
        "tmux" => "foundation/terminal"
      },
      "packages" => [
        %{"id" => "nvim", "name" => "nvim", "targets" => [".config/nvim"]},
        %{"id" => "helix", "name" => "helix", "targets" => [".config/helix"]},
        %{"id" => "tmux", "name" => "tmux", "targets" => [".config/tmux"]}
      ],
      "graph_order" => ["tmux", "helix", "nvim"],
      "journal" => %{"generation" => 2, "revision" => 7, "applied_at" => "2026-02-13T10:00:00Z"}
    }
  end

  defp plan_wire do
    %{
      "generation" => "gen-3",
      "plan" => %{
        "entries" => [
          %{
            "source_name" => "dot_config/nvim/init.lua",
            "target" => ".config/nvim/init.lua",
            "attribution" => ["nvim"]
          },
          %{
            "source_name" => "dot_config/helix/config.toml",
            "target" => ".config/helix/config.toml",
            "attribution" => ["helix"]
          },
          %{
            "source_name" => "dot_config/tmux/tmux.conf",
            "target" => ".config/tmux/tmux.conf",
            "attribution" => ["tmux"]
          }
        ],
        "removals" => []
      },
      "patches" => [
        %{
          "target" => ".config/nvim/init.lua",
          "kind" => "write",
          "attribution" => ["nvim"]
        },
        %{
          "target" => ".config/tmux/tmux.conf",
          "kind" => "write",
          "attribution" => ["tmux"]
        }
      ]
    }
  end

  defp diff_wire do
    %{
      "destination" => @destination,
      "backend_diff" => [
        %{"kind" => "write", "target" => ".config/nvim/init.lua", "source" => "nvim/init.lua"}
      ]
    }
  end

  defp loader(overrides \\ %{}) do
    answers =
      Map.merge(
        %{status: {:ok, status_wire()}, plan: {:ok, plan_wire()}, diff: {:ok, diff_wire()}},
        overrides
      )

    fn wire ->
      case Map.fetch!(answers, wire) do
        fun when is_function(fun, 0) -> fun.()
        value -> value
      end
    end
  end

  defp shell_opts(extra \\ []) do
    Keyword.merge(
      [
        destination: @destination,
        theme: Theme.base_colors(:dark),
        toast_ms: 60_000,
        load: loader(),
        # The shell's own availability probe: pinned to the real
        # "behind" verdict unless a test pins its own.
        check: fn -> {:ok, %{"status" => "behind", "local" => "v1", "remote" => "v2"}} end,
        executor: fn _plan ->
          Process.sleep(10)
          :ok
        end,
        update_executor: fn _flow ->
          Process.sleep(10)
          :ok
        end
      ],
      extra
    )
  end

  # 100 cols < 110: the dashboard renders as the priority stack.
  defp start_shell(extra \\ []),
    do: start_screen!(Shell, rows: 30, cols: 100, screen_opts: shell_opts(extra))

  # 130 cols >= 110: the slot mosaic (fills + fixed bands) at the same
  # row pinning — used where stacked elision would clip asserted rows.
  defp start_shell_wide(extra \\ []),
    do: start_screen!(Shell, rows: 30, cols: 130, screen_opts: shell_opts(extra))

  # Forces a deterministic redraw and drains: the quiet window (100ms)
  # resolves the instantly-answering seams before assertions read rows.
  # NOTE: resize dissolves preset tracking — never settle a frame that
  # must keep a p/P preset; await or take the latest instead.
  defp settled_frame(runtime) do
    send_event(runtime, Event.resize(100, 30))
    latest_frame()
  end

  # Settles the initial async burst (wires + availability probe): every
  # data-dependent assertion and keypress gate needs the loaded home, not
  # the first quiet frame (which can predate the loads under parallel
  # suite load). Rides the draws until the engine identity and the caps
  # rollup are both on screen, then forces one last redraw to drain.
  defp loaded_frame(runtime) do
    frame =
      await_frame(fn frame ->
        text = body_text(frame)
        text =~ "9.9.9-test" and text =~ "rollup:"
      end)

    send_event(runtime, Event.resize(100, 30))
    latest_frame()
    frame
  end

  # Settles the initial async burst (wires + availability probe) WITHOUT
  # the deterministic resize: a resize dissolves preset tracking, so
  # preset-cycle tests settle on the await gate alone.
  defp settled_loads do
    await_frame(fn frame ->
      text = body_text(frame)
      text =~ "9.9.9-test" and text =~ "rollup:"
    end)
  end

  # -- shell chrome ---------------------------------------------------------

  test "init renders the global chrome: keycap strip, dashboard, footer keys" do
    start_shell()

    # The journal box folds the gen/rev pair into its first row once the
    # status read lands.
    frame = await_frame(fn f -> body_text(f) =~ "rev 7" end)

    # The strip is the first row (the only chrome above the dashboard):
    # one glowing island per visible box, the hidden ones dimmed, then
    # the preset keys. The old header (brand island, identity counters,
    # double rule) is gone — gen/rev live in the journal box, version/
    # platform in the engine box, the destination in the status box.
    strip = Frame.row_text(frame, 1)
    assert strip =~ "¹engine"
    assert strip =~ "²capabilities"
    assert strip =~ "³journal"
    assert strip =~ "⁴plan"
    assert strip =~ "⁵diff"
    assert strip =~ "⁶status"
    assert strip =~ "p next"
    assert strip =~ "P prev"
    refute strip =~ @destination
    refute full_text(frame) =~ "══"

    # The dashboard starts directly under the strip.
    assert frame |> Frame.row_text(2) =~ "╭"
    assert body_text(frame) =~ "9.9.9-test"
    assert body_text(frame) =~ "2 · rev 7"

    assert frame |> Frame.row_text(30) =~ "1-6 toggle"
    assert frame |> Frame.row_text(30) =~ "p/P layout"
    assert frame |> Frame.row_text(30) =~ "? help"
    assert frame |> Frame.row_text(30) =~ "q quit"
    # Tab is gone from the dashboard entirely: no arrows, no tab count.
    refute Frame.row_text(frame, 30) =~ "←→"
    refute Frame.row_text(frame, 30) =~ "tabs"
  end

  # -- btop grammar: slots pinned by frame cells -----------------------------

  test "the strip renders the digit in the keycap slot, visible boxes in accent" do
    runtime = start_shell()
    frame = settled_frame(runtime)

    # Buttonbar islands: `┘¹engine└┘²capabilities└…`. The connector reads
    # chrome, the digit rides the keycap slot (dark base #bb9af7), the
    # label rides the accent role (dark base #7aa2f7) — every VISIBLE
    # box glows; only hidden boxes dim to inactive.
    assert Frame.cell(frame, 1, 1).char == "┘"
    assert Frame.cell(frame, 1, 2).char == "¹"
    assert Frame.cell(frame, 1, 2).fg == {187, 154, 247}
    assert Frame.cell(frame, 1, 3).char == "e"
    assert Frame.cell(frame, 1, 3).fg == {122, 162, 247}

    # `┘¹engine└` spans columns 1..9; the next island's connector rides
    # column 10, its digit the keycap slot.
    assert Frame.cell(frame, 1, 10).char == "┘"
    assert Frame.cell(frame, 1, 11).char == "²"
    assert Frame.cell(frame, 1, 11).fg == {187, 154, 247}
    assert Frame.cell(frame, 1, 12).char == "c"
    assert Frame.cell(frame, 1, 12).fg == {122, 162, 247}
  end

  test "keycap/1 renders btop's superscript table with clamping" do
    # btop_draw.cpp:87 Symbols::superscript — the title-grammar table.
    assert Shell.keycap(0) == "⁰"
    assert Shell.keycap(1) == "¹"
    assert Shell.keycap(3) == "³"
    assert Shell.keycap(7) == "⁷"
    assert Shell.keycap(9) == "⁹"

    # Outside 0-9 clamps into the table (btop superscript.at(clamp(num, 0, 9)))
    assert Shell.keycap(10) == "⁹"
    assert Shell.keycap(-1) == "⁰"
  end

  test "strip islands use the exact btop no-space keycap construction" do
    runtime = start_shell()
    frame = loaded_frame(runtime)

    # `┘¹engine└`, never the spaced `┘1 engine└` form — the plain-digit
    # variant stays a narrow-TTY opt-in, never the default.
    strip = Frame.row_text(frame, 1)
    assert strip =~ "┘¹engine└"
    assert strip =~ "┘²capabilities└"
    refute strip =~ "¹ engine"
    refute strip =~ "1engine"
  end

  test "footer keeps frame keys only, key caps in the shortcut slot" do
    runtime = start_shell()
    frame = settled_frame(runtime)

    footer = Frame.row_text(frame, 30)
    # btop buttonbar: each key rides its own island (┘key label└).
    assert footer =~ "┘1-6 toggle└"
    assert footer =~ "┘p/P layout└"
    assert footer =~ "┘? help└"
    assert footer =~ "┘q quit└"
    # The drill grammar moves into the capabilities box at M2; the global
    # footer keeps frame keys only.
    refute footer =~ "expand"
    refute footer =~ "collapse"

    # Key caps glow in the shortcut slot (after the ┘ connector).
    assert Frame.cell(frame, 30, 1).char == "┘"
    assert Frame.cell(frame, 30, 2).fg == {187, 154, 247}
  end

  test "home lists every verb's surface once the reads land" do
    _runtime = start_shell_wide()

    # Reads AND the availability probe land asynchronously — ride the
    # draws until both are on screen, then assert the full surface.
    frame =
      await_frame(fn frame ->
        text = full_text(frame)
        text =~ "9.9.9-test" and text =~ "update available"
      end)

    text = body_text(frame)

    assert full_text(frame) =~ "9.9.9-test"
    assert text =~ "generation:  2"
    assert text =~ "generation:  gen-3"
    assert text =~ "1 pending change(s)"
    # editor (nvim+helix: 2 files) + terminal (tmux: 1 file) = 2 domains.
    assert text =~ "2 domains · 3 files · 2 would change"
    assert text =~ "● reachable"
    assert text =~ "a apply"
    # The probe says an update exists → the affordances show: the hint
    # rides the capabilities band body; the button rides the home
    # buttonbar.
    assert full_text(frame) =~ "update available"
    assert text =~ "u update"
  end

  # -- digits toggle boxes; p/P cycles presets -------------------------------

  test "digit keys toggle dashboard boxes and the strip dims hidden islands" do
    runtime = start_shell()
    loaded_frame(runtime)

    send_text(runtime, "4")
    frame = await_frame(fn f -> Frame.row_text(f, 1) =~ "[4] plan" end)
    # The plan box is gone from the body; the island renders dimmed.
    refute body_text(frame) =~ "⁴plan"
    assert Frame.row_text(frame, 1) =~ "[4] plan"

    # Toggling it back restores the box and the glowing island.
    send_text(runtime, "4")
    frame = await_frame(fn f -> Frame.row_text(f, 1) =~ "⁴plan" end)
    assert body_text(frame) =~ "⁴plan"
    refute Frame.row_text(frame, 1) =~ "[4] plan"

    # 0 and 7+ are inert (btop: only the 1-6 boxed regions toggle).
    send_text(runtime, "7")
    send_text(runtime, "0")
    frame = settled_frame(runtime)
    assert Frame.row_text(frame, 1) =~ "⁶status"
    assert body_text(frame) =~ "⁴plan"
  end

  test "toggling a box back on below its minimum width refuses with a footer flash" do
    runtime = start_screen!(Shell, rows: 30, cols: 56, screen_opts: shell_opts())

    await_frame(fn f -> body_text(f) =~ "9.9.9-test" end)

    # Hiding is always allowed…
    send_text(runtime, "2")
    assert await_frame(fn f -> Frame.row_text(f, 1) =~ "[2] capabilities" end) |> Frame.row_text(1) =~
             "[2] capabilities"

    # …but showing it again at 56 cols violates the capabilities floor
    # (62): the tiler refuses and the flash names the box and the floor.
    send_text(runtime, "2")
    frame = await_frame(fn f -> Frame.row_text(f, 30) =~ "capabilities needs >= 62 columns" end)
    assert Frame.row_text(frame, 30) =~ "capabilities needs >= 62 columns"
    # The refusal leaves the layout untouched: the island stays dimmed.
    assert Frame.row_text(frame, 1) =~ "[2] capabilities"
  end

  test "p cycles presets: full mosaic → audit → minimal → wraps" do
    runtime = start_shell()
    settled_loads()

    # Preset 1 (audit): plan+diff fill the top, engine+journal ride the
    # bottom band; capabilities and status hide.
    send_text(runtime, "p")
    frame =
      await_frame(fn f ->
        text = body_text(f)
        text =~ "⁴plan" and text =~ "⁵diff" and text =~ "¹engine" and text =~ "³journal" and
          not (text =~ "²capabilities") and not (text =~ "⁶status")
      end)

    assert Frame.row_text(frame, 1) =~ "[2] capabilities"
    assert Frame.row_text(frame, 1) =~ "[6] status"

    # Preset 2 (minimal): engine+journal only.
    send_text(runtime, "p")
    frame =
      await_frame(fn f ->
        text = body_text(f)
        text =~ "¹engine" and text =~ "³journal" and not (text =~ "⁴plan") and
          not (text =~ "⁶status")
      end)

    assert Frame.row_text(frame, 1) =~ "[4] plan"

    # The third p wraps back to preset 0 (full mosaic).
    send_text(runtime, "p")
    frame =
      await_frame(fn f ->
        text = body_text(f)
        text =~ "²capabilities" and text =~ "⁶status"
      end)

    refute Frame.row_text(frame, 1) =~ "[2] capabilities"
  end

  test "P cycles backwards and resize dissolves preset tracking" do
    runtime = start_shell()
    settled_loads()

    # P from preset 0 wraps to preset 2 (minimal).
    send_text(runtime, "P")

    frame =
      await_frame(fn f ->
        text = body_text(f)
        text =~ "¹engine" and text =~ "³journal" and not (text =~ "⁴plan") and
          not (text =~ "⁶status")
      end)

    assert Frame.row_text(frame, 1) =~ "[4] plan"

    # Any resize dissolves the tracking: the preset bond breaks and the
    # generic tiler takes over the LAYOUT. Membership is kept — boxes
    # hidden by the preset stay hidden until toggled back — but the
    # arrangement reverts: from the audit preset, the generic slot
    # mosaic at 110 cols pins engine|journal on TOP, while the audit
    # preset had plan|diff there.
    # preset: nil → :next seeds -1 → preset 0. But P has SET preset 2
    # (tracking active), so p wraps 2 → 0 → 1: two presses land on audit.
    send_text(runtime, "p")
    send_text(runtime, "p")

    await_frame(fn f ->
      text = body_text(f)
      text =~ "⁴plan" and find_row(f, "⁴plan") < find_row(f, "¹engine")
    end)

    send_event(runtime, Event.resize(110, 30))

    frame =
      await_frame(fn f ->
        text = body_text(f)

        text =~ "¹engine" and text =~ "⁴plan" and not (text =~ "²capabilities") and
          not (text =~ "⁶status") and
          find_row(f, "¹engine") < find_row(f, "⁴plan")
      end)

    assert frame.width == 110
    # Membership survives the dissolve: the capabilities island stays dimmed.
    assert Frame.row_text(frame, 1) =~ "[2] capabilities"
  end

  # -- help overlay ----------------------------------------------------------

  test "? opens the paged help overlay; ? closes it" do
    runtime = start_shell()
    loaded_frame(runtime)

    send_text(runtime, "?")
    text = await_frame(fn f -> Frame.row_text(f, 2) =~ "?help" end) |> body_text()

    assert text =~ "dashboard (the one screen)"
    assert text =~ "1..6"
    assert text =~ "capabilities"

    # The help is longer than the pane: it scrolls (nothing clipped).
    send_key(runtime, :end)
    text = settled_frame(runtime) |> body_text()

    assert text =~ "standalone entry points"
    assert text =~ "--headless"
    assert text =~ "bare `workstation` opens this app on a terminal"
    assert text =~ "without a TTY"
    assert text =~ "keeps running daemon-side"

    # ? closes the overlay and returns to the living dashboard.
    send_text(runtime, "?")
    frame =
      await_frame(fn f ->
        text = body_text(f)
        text =~ "9.9.9-test" and not (text =~ "dashboard (the one screen)")
      end)

    assert body_text(frame) =~ "9.9.9-test"
  end

  # -- embedded apply / update screens ---------------------------------------

  test "a opens the apply screen INSIDE the app (chrome unchanged, body swaps)" do
    runtime = start_shell()
    # Settle first: `a` needs the plan wire loaded (the key would race
    # the initial async loads otherwise).
    loaded_frame(runtime)
    send_text(runtime, "a")
    frame = await_frame(fn f -> body_text(f) =~ "apply · #{@destination}" end)

    # The strip keeps the six-box grammar while an op screen owns the
    # body — ops are workflows over the dashboard, not new tabs.
    assert Frame.row_text(frame, 1) =~ "¹engine"
    refute Frame.row_text(frame, 1) =~ "apply"
    text = body_text(frame)
    assert text =~ "apply · #{@destination}"
    assert text =~ "gen gen-3"
    assert text =~ "3 changes"
    # op mode — the shell keeps only the strip above the screen, so the
    # screen's own footer is the last body row.
    assert Frame.row_text(frame, 30) =~ "a confirm"
  end

  test "embedded apply run completes, then [u] swaps to the update screen" do
    runtime = start_shell()
    loaded_frame(runtime)
    send_text(runtime, "a")
    assert settled_frame(runtime) |> body_text() =~ "apply · #{@destination}"

    # a opens the confirm dialog; y runs. The dialog documents its keys
    # on the screen's own border buttonbar. The key event rides the
    # screen's async loop — wait for the dialog instead of trusting one
    # drain.
    send_text(runtime, "a")
    frame =
      await_frame(fn frame ->
        body_text(frame) =~ "Confirm apply"
      end)
    assert Frame.row_text(frame, 30) =~ "y confirm apply"
    send_text(runtime, "y")

    # The run is an async executor round-trip: a single quiet window can
    # close before its answer lands (the one shell_test flake read the
    # in-flight frame as settled), so ride the draws until the applied
    # frame arrives — bounded, never a hang.
    await_frame(fn frame -> body_text(frame) =~ "Applied generation gen-3" end)

    # The screen's own [u] handoff — now it swaps screens, not processes.
    send_text(runtime, "u")
    frame = settled_frame(runtime)
    assert Frame.row_text(frame, 1) =~ "¹engine"
    assert body_text(frame) =~ "update · #{@destination}"
    refute Frame.row_text(frame, 1) =~ "update"
  end

  test "q inside an op screen returns to the dashboard and re-reads (daemon keeps running)" do
    runtime = start_shell()
    loaded_frame(runtime)
    send_text(runtime, "a")
    assert await_frame(fn f -> body_text(f) =~ "apply · #{@destination}" end) |> body_text() =~
             "apply · #{@destination}"

    send_text(runtime, "q")
    frame = await_frame(fn f -> Frame.row_text(f, 1) =~ "¹engine" end)
    assert Frame.row_text(frame, 1) =~ "¹engine"
    assert body_text(frame) =~ "9.9.9-test"
    refute body_text(frame) =~ "apply · "
  end

  test "u on home opens the update screen when the probe found updates" do
    runtime = start_shell_wide()
    # `u` needs the shell's availability probe verdict — await the hint
    # (it rides the capabilities band body, not the home body).
    await_frame(fn frame -> full_text(frame) =~ "update available" end)
    send_text(runtime, "u")
    frame = settled_frame(runtime)

    assert Frame.row_text(frame, 1) =~ "¹engine"
    assert body_text(frame) =~ "update · #{@destination}"
  end

  test "q on the dashboard quits the app (the footer's documented quit key)" do
    runtime = start_shell()
    loaded_frame(runtime)

    send_text(runtime, "q")
    snapshot = shutdown_snapshot()
    assert snapshot.shutdown_reason == :normal
  end

  test "up-to-date probe: no hint row and u on home is a no-op" do
    runtime = start_shell_wide(check: fn -> {:ok, %{"status" => "up_to_date"}} end)
    frame = settled_frame(runtime)

    refute body_text(frame) =~ "update available"

    send_text(runtime, "u")
    frame = settled_frame(runtime)
    assert Frame.row_text(frame, 1) =~ "¹engine"
    refute body_text(frame) =~ "update available"
  end

  # -- status box ------------------------------------------------------------

  test "status box reports the deep rows from the live status read" do
    _runtime = start_shell_wide()

    # Bind the awaited frame itself: no further draw is pending, so a
    # bare latest_frame/0 drain would wait on a redraw that never comes.
    frame = await_frame(fn frame -> body_text(frame) =~ "destination:" end)
    text = body_text(frame)
    assert text =~ "destination:  #{@destination}"
    assert text =~ "graph order:"
    assert text =~ "3 resolved"
  end

  test "status box shows the recovery shape when the daemon is unreachable" do
    runtime =
      start_shell_wide(load: loader(%{status: {:error, {"daemon_unavailable", "ENOENT"}}}))

    # The status read rides its own async seam (loading → unreachable).
    text =
      await_frame(fn frame ->
        body_text(frame) =~ "daemon unreachable"
      end) |> body_text()

    assert text =~ "daemon unreachable"
    assert text =~ "workstation daemon"

    # r retries the read (the seam keeps failing; the error stays honest).
    # The reload is an async seam round-trip — ride the draws for the
    # re-failed shape instead of trusting one drain to land after it.
    send_text(runtime, "r")

    assert await_frame(fn f -> body_text(f) =~ "retry with r" end) |> body_text() =~
             "retry with r"
  end

  # -- btop grammar: borders, ramps, per-domain accents ----------------------

  test "journal line rides the magnitude ramp by applied-at age (fresh/aging/stale)" do
    # The journal box's applied row sits wherever the responsive home puts
    # the box, so the row is located by its label instead of a pinned row
    # number. The wide harness (slot mosaic) keeps both journal rows
    # visible; the ramp reads the VALUE cell of the applied row.
    ramp_cell = fn now ->
      _runtime = start_shell_wide(now: now)
      frame = await_frame(fn frame -> body_text(frame) =~ "generation:" end)
      row = applied_row(frame)
      Frame.cell(frame, row, value_col(frame, row, "applied")).fg
    end

    # fresh (<24h) → ramp_start (ok slot family)
    assert ramp_cell.(~U[2026-02-13T12:00:00Z]) == {158, 206, 106}

    # aging (<7d) → ramp_mid (warn family)
    assert ramp_cell.(~U[2026-02-16T10:00:00Z]) == {224, 175, 104}

    # stale (≥7d) → ramp_end (err family)
    assert ramp_cell.(~U[2026-05-01T10:00:00Z]) == {247, 118, 142}
  end

  test "the engine badge tints reachable state accent and unreachable err" do
    _runtime = start_shell()

    # The badge rides the engine box border once the status read lands —
    # a settled drain can predate the load under suite load.
    frame = await_frame(fn frame -> body_text(frame) =~ "● reachable" end)

    row = find_row(frame, "● reachable")
    assert row > 1
    assert fg_in_row?(frame, row, {122, 162, 247})

    _runtime = start_shell(load: loader(%{status: {:error, {"daemon_unavailable", "ENOENT"}}}))

    # The error loader means the home never shows the engine identity —
    # the readiness gate is the engine badge's unreachable verdict.
    frame =
      await_frame(fn frame ->
        body_text(frame) =~ "● unreachable"
      end)

    row = find_row(frame, "● unreachable")
    assert row > 1
    assert fg_in_row?(frame, row, {247, 118, 142})
  end

  test "read failures render in the err slot" do
    _runtime = start_shell(load: loader(%{status: {:error, {"plan_stale", "nope"}}}))

    # The status read fails ASYNC through the load seam — match every
    # arriving frame for the err-tinted failure row instead of trusting
    # one settled drain to land after the wire answer.
    frame =
      await_frame(fn frame ->
        row = find_row(frame, "read failed")
        row > 1 and fg_in_row?(frame, row, {247, 118, 142})
      end)

    row = find_row(frame, "read failed")
    assert row > 1
    assert fg_in_row?(frame, row, {247, 118, 142})
  end

  # -- mouse -----------------------------------------------------------------

  test "a left click on a strip island toggles that box" do
    runtime = start_shell()
    loaded_frame(runtime)

    # Islands are back-to-back: `┘¹engine└` spans 0-based columns 0..8,
    # `┘²capabilities└` spans 9..23 — column 10 is inside capabilities
    # at any width. Clicking a visible box HIDES it (digit semantics).
    send_event(runtime, %Event.Mouse{action: :press, button: :left, x: 10, y: 0})

    frame = await_frame(fn f -> Frame.row_text(f, 1) =~ "[2] capabilities" end)
    refute body_text(frame) =~ "rollup:"

    # Clicking the dimmed island again restores the box.
    send_event(runtime, %Event.Mouse{action: :press, button: :left, x: 10, y: 0})
    frame = await_frame(fn f -> Frame.row_text(f, 1) =~ "²capabilities" end)
    assert body_text(frame) =~ "rollup:"
  end

  test "clicks on the chrome filler and off the strip row stay inert" do
    runtime = start_shell()
    loaded_frame(runtime)

    # The islands cost 73 columns at the harness's 100; column 95 is
    # chrome filler. A click there must not touch the dashboard.
    send_event(runtime, %Event.Mouse{action: :press, button: :left, x: 95, y: 0})
    text = settled_frame(runtime) |> body_text()
    assert text =~ "rollup:"
    assert text =~ "⁴plan"

    # A body click (the first body row) is not a strip click.
    send_event(runtime, %Event.Mouse{action: :press, button: :left, x: 10, y: 1})
    text = settled_frame(runtime) |> body_text()
    assert text =~ "rollup:"
    assert text =~ "⁴plan"
  end

  test "a left click on the p island cycles the preset" do
    runtime = start_shell()
    settled_loads()

    # `┘p next└` spans 0-based columns 57..64; column 60 is inside it.
    send_event(runtime, %Event.Mouse{action: :press, button: :left, x: 60, y: 0})

    frame =
      await_frame(fn f ->
        text = body_text(f)
        text =~ "⁴plan" and not (text =~ "²capabilities")
      end)

    assert Frame.row_text(frame, 1) =~ "[2] capabilities"
  end

  test "island clicks resolve through the same walk the renderer draws" do
    # Plain-map state: the walk only reads the dashboard's island keys.
    state = %{dashboard: Workstation.CLI.TUI.Shell.Dashboard.new(), op: nil}

    click = fn x, y, button ->
      Shell.event_to_msg(%Event.Mouse{action: :press, button: button, x: x, y: y}, state)
    end

    # Island boundaries at any width: engine 0..8, capabilities 9..23,
    # plan 34..40, p 57..64 — filler beyond 73 is inert.
    assert click.(3, 0, :left) == {:msg, {:text, "1"}}
    assert click.(9, 0, :left) == {:msg, {:text, "2"}}
    assert click.(36, 0, :left) == {:msg, {:text, "4"}}
    assert click.(60, 0, :left) == {:msg, {:text, "p"}}
    assert click.(73, 0, :left) == :ignore
    assert click.(400, 0, :left) == :ignore

    # Only left presses address islands; everything else is inert.
    assert click.(3, 0, :right) == :ignore
    assert Shell.event_to_msg(
             %Event.Mouse{action: :release, button: :left, x: 3, y: 0},
             state
           ) == :ignore

    assert Shell.event_to_msg(
             %Event.Mouse{action: :move, button: nil, x: 3, y: 0},
             state
           ) == :ignore

    # The strip is 0-based row 0 — a click on the first body row is inert.
    assert click.(3, 1, :left) == :ignore
  end

  test "the wheel reuses the pane scroll keys (position counter steps 1 → 2)" do
    runtime = start_shell()

    send_text(runtime, "?")
    frame = await_frame(fn f -> Frame.row_text(f, 2) =~ "?help" end)
    # The pane's bottom action bar carries the first-visible/total counter.
    assert Frame.row_text(frame, 29) =~ ~r/1\/\d+/

    # One wheel notch == one :down wherever the pointer sits — here over
    # the help box's body cells.
    send_event(runtime, %Event.Mouse{action: :scroll_down, button: nil, x: 40, y: 15})

    scrolled = await_frame(fn f -> Frame.row_text(f, 29) =~ ~r/2\/\d+/ end)
    assert Frame.row_text(scrolled, 2) =~ "?help"
  end

  test "the wheel never touches the chrome, at any pointer position" do
    state = %{dashboard: Workstation.CLI.TUI.Shell.Dashboard.new(), op: nil}

    assert Shell.event_to_msg(
             %Event.Mouse{action: :scroll_up, button: nil, x: 3, y: 3},
             state
           ) == {:msg, {:key, :up}}

    assert Shell.event_to_msg(
             %Event.Mouse{action: :scroll_down, button: nil, x: 95, y: 3},
             state
           ) == {:msg, {:key, :down}}

    assert Shell.event_to_msg(
             %Event.Mouse{action: :scroll_down, button: nil, x: 4_000, y: 4_000},
             state
           ) == {:msg, {:key, :down}}
  end

  test "TUI.run brackets the run with the mouse enable/disable sequences" do
    opts = [
      theme: Theme.base_colors(:dark),
      destination: @destination,
      backend:
        {DeterministicBackend,
         owner: self(), size: {24, 80}, capabilities: %{colors: :ansi_16, unicode: true}},
      render_interval: 1
    ]

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:error, _probe} =
                 Workstation.CLI.TUI.run(ShellTest.MouseProbeScreen, opts)
      end)

    assert String.starts_with?(output, "\e[?1000h\e[?1006h"),
           "enable sequences must be written before the run, got: #{inspect(output)}"

    # The after-clause runs on the probe's init failure: both disable
    # sequences land, back to back, even when the app never rendered.
    assert output =~ "\e[?1006l\e[?1000l"
  end

  # -- resize ----------------------------------------------------------------

  test "resize reflows the chrome and the embedded screen" do
    runtime = start_shell()
    loaded_frame(runtime)
    send_text(runtime, "a")
    frame = settled_frame(runtime)
    assert Frame.row_text(frame, 1) =~ "¹engine"
    assert Frame.row_text(frame, 2) =~ "apply · #{@destination}"

    send_event(runtime, Event.resize(120, 40))

    # The resize event rides the screen's async event loop — wait for
    # the reflowed frame instead of trusting one drain.
    frame =
      await_frame(fn frame ->
        frame.width == 120
      end)

    assert frame.width == 120
    # The op survives the resize; the embedded screen re-laid itself out
    # to the body rect of the new size (its box re-renders under the
    # shell chrome).
    assert Frame.row_text(frame, 2) =~ "apply · #{@destination}"
  end

  # -- helpers -----------------------------------------------------------------

  defp body_text(frame) do
    # The strip is row 1; the body spans rows 2..(height-1) and the shell
    # footer is the last row (op mode's own footer included).
    2..(frame.height - 1)
    |> Enum.map(&Frame.row_text(frame, &1))
    |> Enum.join("\n")
  end

  # The full frame — strip and footer included; with the header gone,
  # body_text already covers the loaded home's data rows, so this only
  # differs by the chrome rows.
  defp full_text(frame) do
    1..frame.height
    |> Enum.map(&Frame.row_text(frame, &1))
    |> Enum.join("\n")
  end

  # 1-based row of the first BODY row containing `needle`. The strip
  # (row 1) and footer (last row) are chrome — every box title, data row
  # and badge lives in the body — so the search skips both; a needle that
  # exists only on the chrome rows (keycap islands) is not found.
  defp find_row(frame, needle) do
    2..(frame.height - 1)
    |> Enum.find(&(Frame.row_text(frame, &1) =~ needle))
  end

  defp fg_in_row?(frame, row, rgb) do
    1..frame.width
    |> Enum.any?(fn col -> Frame.cell(frame, row, col).fg == rgb end)
  end

  # 1-based column of the first non-space cell after `label:` in a row.
  # :binary.match byte offsets == cell columns for ASCII labels.
  defp value_col(frame, row, label) do
    text = Frame.row_text(frame, row)
    {pos, _len} = :binary.match(text, label <> ":")
    first_nonspace(text, pos + String.length(label <> ":"))
  end

  defp first_nonspace(text, pos) do
    case String.at(text, pos) do
      nil -> pos + 1
      " " -> first_nonspace(text, pos + 1)
      _char -> pos + 1
    end
  end

  # The journal box's applied-at stamp row, found by its label (the only
  # "applied:" on the home body — the rollup line reads "applied gen-2"
  # without a colon).
  defp applied_row(frame) do
    row = Enum.find(2..(frame.height - 1), &String.contains?(Frame.row_text(frame, &1), "applied:"))
    assert row, "journal applied row not found on the home frame"
    row
  end
end
