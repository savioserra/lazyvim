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

  test "init renders the global chrome: dashboard boxes, footer keys" do
    start_shell()

    # The journal box folds the gen/rev pair into its first row once the
    # status read lands.
    frame = await_frame(fn f -> body_text(f) =~ "rev 7" end)

    # The dashboard owns the whole terminal but the footer row: one
    # keycap-titled box per visible box (the superscript titles are the
    # only toggle advertising — there is no strip row anymore), then the
    # preset keys on the footer. The old header (brand island, identity
    # counters, double rule) is gone — gen/rev live in the journal box,
    # version/platform in the engine box, the destination in the status
    # box.
    for title <- ~w(¹engine ²capabilities ³journal ⁴plan ⁵diff ⁶status) do
      assert body_text(frame) =~ title
    end

    assert Frame.row_text(frame, 1) =~ "╭"
    # No header/strip row exists anymore to carry the destination — it
    # lives in the status box body by design.
    refute Frame.row_text(frame, 1) =~ @destination
    refute full_text(frame) =~ "══"

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

  test "box titles render the digit in the keycap slot on the top border" do
    runtime = start_shell()
    frame = settled_frame(runtime)

    # Title construction `╭─┐¹engine┌…`: the digit rides the keycap slot
    # (shortcut role #c695ff, bold), the label rides the text role
    # (#f5f5dc) — the old strip's accent labels are gone with the strip.
    engine_r = find_row(frame, "¹engine")
    assert Frame.cell(frame, engine_r, 3).char == "┐"
    assert Frame.cell(frame, engine_r, 4).char == "¹"
    assert Frame.cell(frame, engine_r, 4).fg == {198, 149, 255}
    assert Frame.cell(frame, engine_r, 5).char == "e"
    assert Frame.cell(frame, engine_r, 5).fg == {245, 245, 220}
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

  test "box titles use the exact btop no-space keycap construction" do
    runtime = start_shell()
    frame = loaded_frame(runtime)

    # `┐¹engine┌`, never the spaced `┐¹ engine┌` form — the plain-digit
    # variant stays a narrow-TTY opt-in, never the default.
    # At the harness's 100 columns the stack layout owns row 1 with the
    # engine box.
    top = Frame.row_text(frame, 1)
    assert top =~ "┐¹engine┌"
    refute top =~ "¹ engine"
    refute top =~ "1engine"
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
    assert Frame.cell(frame, 30, 2).fg == {198, 149, 255}
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

  test "digit keys toggle dashboard boxes on and off" do
    runtime = start_shell()
    loaded_frame(runtime)

    send_text(runtime, "4")
    frame = await_frame(fn f -> not (body_text(f) =~ "⁴plan") end)
    # The plan box is gone from the body — no dimmed strip island
    # renders it anymore (the superscript titles are the only
    # toggle advertising).
    refute body_text(frame) =~ "⁴plan"

    # Toggling it back restores the box.
    send_text(runtime, "4")
    frame = await_frame(fn f -> body_text(f) =~ "⁴plan" end)
    assert body_text(frame) =~ "⁴plan"

    # 0 and 7+ are inert (btop: only the 1-6 boxed regions toggle).
    send_text(runtime, "7")
    send_text(runtime, "0")
    frame = settled_frame(runtime)
    assert body_text(frame) =~ "⁶status"
    assert body_text(frame) =~ "⁴plan"
  end

  test "toggling a box back on below its minimum width refuses with a footer flash" do
    runtime = start_screen!(Shell, rows: 30, cols: 56, screen_opts: shell_opts())

    await_frame(fn f -> body_text(f) =~ "9.9.9-test" end)

    # Hiding is always allowed…
    send_text(runtime, "2")
    assert await_frame(fn f -> not (body_text(f) =~ "²capabilities") end) |> body_text() =~
             "¹engine"

    # …but showing it again at 56 cols violates the capabilities floor
    # (62): the tiler refuses and the flash names the box and the floor.
    send_text(runtime, "2")
    frame = await_frame(fn f -> Frame.row_text(f, 30) =~ "capabilities needs >= 62 columns" end)
    assert Frame.row_text(frame, 30) =~ "capabilities needs >= 62 columns"
    # The refusal leaves the layout untouched: the box stays hidden.
    refute body_text(frame) =~ "²capabilities"
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

    # Preset 2 (minimal): engine+journal only.
    send_text(runtime, "p")
    frame =
      await_frame(fn f ->
        text = body_text(f)
        text =~ "¹engine" and text =~ "³journal" and not (text =~ "⁴plan") and
          not (text =~ "⁶status")
      end)

    # The third p wraps back to preset 0 (full mosaic).
    send_text(runtime, "p")
    frame =
      await_frame(fn f ->
        text = body_text(f)
        text =~ "²capabilities" and text =~ "⁶status"
      end)
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
    # Membership survives the dissolve: the box stays hidden.
    refute body_text(frame) =~ "²capabilities"
  end

  # -- help overlay ----------------------------------------------------------

  test "? opens the paged help overlay; ? closes it" do
    runtime = start_shell()
    loaded_frame(runtime)

    send_text(runtime, "?")
    text = await_frame(fn f -> Frame.row_text(f, 1) =~ "?help" end) |> body_text()

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

    # The op screen owns the whole body — ops are workflows over the
    # dashboard, not new tabs; no dashboard chrome survives above it.
    refute body_text(frame) =~ "¹engine"
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

    # a opens the typed-confirm gate; the typed verb arms, Enter fires
    # (spec §2.3). The gate documents its keys on the screen's own border
    # buttonbar. The key events ride the screen's async loop — wait for
    # the dialog instead of trusting one drain.
    send_text(runtime, "a")
    frame =
      await_frame(fn frame ->
        body_text(frame) =~ "Confirm apply"
      end)
    assert Frame.row_text(frame, 30) =~ "enter confirm apply"
    assert Frame.row_text(frame, 30) =~ "n cancel"
    "apply" |> String.graphemes() |> Enum.each(&send_text(runtime, &1))
    send_key(runtime, :enter)

    # The run is an async executor round-trip: a single quiet window can
    # close before its answer lands (the one shell_test flake read the
    # in-flight frame as settled), so ride the draws until the applied
    # frame arrives — bounded, never a hang. The done phase floats its
    # panel over the mirror of the living dashboard (§1.6) and the
    # toast lands bottom-right.
    frame =
      await_frame(fn frame ->
        body_text(frame) =~ "Applied generation gen-3"
      end)

    assert body_text(frame) =~ "¹engine"
    assert body_text(frame) =~ "applied — the dashboard below is live again"

    # The screen's own [u] handoff — now it swaps screens, not processes.
    send_text(runtime, "u")
    frame = settled_frame(runtime)
    # The update screen owns the whole body — the dashboard is gone.
    refute body_text(frame) =~ "¹engine"
    assert body_text(frame) =~ "update · #{@destination}"
  end

  test "q inside an op screen returns to the dashboard and re-reads (daemon keeps running)" do
    runtime = start_shell()
    loaded_frame(runtime)
    send_text(runtime, "a")
    assert await_frame(fn f -> body_text(f) =~ "apply · #{@destination}" end) |> body_text() =~
             "apply · #{@destination}"

    send_text(runtime, "q")
    frame = await_frame(fn f -> body_text(f) =~ "9.9.9-test" end)
    assert Frame.row_text(frame, 1) =~ "╭"
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

    refute body_text(frame) =~ "¹engine"
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
    frame = await_frame(fn f -> body_text(f) =~ "9.9.9-test" end)
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
    assert ramp_cell.(~U[2026-02-13T12:00:00Z]) == {127, 207, 120}

    # aging (<7d) → ramp_mid (warn family)
    assert ramp_cell.(~U[2026-02-16T10:00:00Z]) == {240, 230, 140}

    # stale (≥7d) → ramp_end (err family)
    assert ramp_cell.(~U[2026-05-01T10:00:00Z]) == {255, 121, 121}
  end

  test "the engine badge tints reachable state accent and unreachable err" do
    _runtime = start_shell()

    # The badge rides the engine box border once the status read lands —
    # a settled drain can predate the load under suite load.
    frame = await_frame(fn frame -> body_text(frame) =~ "● reachable" end)

    row = find_row(frame, "● reachable")
    # The badge rides the engine box title - row 1 in the stack layout.
    assert row
    assert fg_in_row?(frame, row, {91, 173, 255})

    _runtime = start_shell(load: loader(%{status: {:error, {"daemon_unavailable", "ENOENT"}}}))

    # The error loader means the home never shows the engine identity —
    # the readiness gate is the engine badge's unreachable verdict.
    frame =
      await_frame(fn frame ->
        body_text(frame) =~ "● unreachable"
      end)

    row = find_row(frame, "● unreachable")
    # The badge rides the engine box title — row 1 in the stack layout.
    assert row
    assert fg_in_row?(frame, row, {255, 121, 121})
  end

  test "read failures render in the err slot" do
    _runtime = start_shell(load: loader(%{status: {:error, {"plan_stale", "nope"}}}))

    # The status read fails ASYNC through the load seam — match every
    # arriving frame for the err-tinted failure row instead of trusting
    # one settled drain to land after the wire answer.
    frame =
      await_frame(fn frame ->
        row = find_row(frame, "read failed")
        row > 1 and fg_in_row?(frame, row, {255, 121, 121})
      end)

    row = find_row(frame, "read failed")
    assert row > 1
    assert fg_in_row?(frame, row, {255, 121, 121})
  end

  # -- mouse -----------------------------------------------------------------

  test "a click on the footer row is inert chrome" do
    runtime = start_shell()
    loaded_frame(runtime)

    # The footer is pure render chrome — clicks address boxes through
    # the dashboard walk, and the footer row sits outside every box.
    send_event(runtime, %Event.Mouse{action: :press, button: :left, x: 95, y: 29})
    text = settled_frame(runtime) |> body_text()
    assert text =~ "rollup:"
    assert text =~ "⁴plan"
  end

  test "box clicks resolve through the same walk the renderer draws" do
    # Plain-map state: the walk only reads the dashboard layout geometry
    # — the exact call the renderer makes, so click = pixels.
    state = %{dashboard: Workstation.CLI.TUI.Shell.Dashboard.new(), op: nil, dimensions: {100, 30}}

    click = fn x, y, button ->
      Shell.event_to_msg(%Event.Mouse{action: :press, button: button, x: x, y: y}, state)
    end

    layout = Workstation.CLI.TUI.Shell.Dashboard.layout(state.dashboard, {100, 29})
    {_, {cx, cy, _cw, _ch}} = Enum.find(layout, fn {box, _} -> box == :capabilities end)
    {_, {ex, ey, _ew, _eh}} = Enum.find(layout, fn {box, _} -> box == :engine end)

    # A left press inside the capabilities cell drills its deep view.
    assert click.(cx + 1, cy + 1, :left) == {:msg, {:box_click, :capabilities}}

    # Non-zoomable boxes pass the raw event through (the pane scroll
    # keys reuse body presses).
    assert click.(ex + 1, ey + 1, :left) ==
             {:msg, %Event.Mouse{action: :press, button: :left, x: ex + 1, y: ey + 1}}

    # Only left presses address boxes; everything else is inert.
    assert click.(cx + 1, cy + 1, :right) == :ignore

    assert Shell.event_to_msg(
             %Event.Mouse{action: :release, button: :left, x: cx + 1, y: cy + 1},
             state
           ) == :ignore

    assert Shell.event_to_msg(
             %Event.Mouse{action: :move, button: nil, x: cx + 1, y: cy + 1},
             state
           ) == :ignore

    # The footer row rides below the layout — a click there is inert.
    assert click.(3, 29, :left) ==
             {:msg, %Event.Mouse{action: :press, button: :left, x: 3, y: 29}}
  end

  test "the wheel reuses the pane scroll keys (position counter steps 1 → 2)" do
    runtime = start_shell()

    send_text(runtime, "?")
    frame = await_frame(fn f -> Frame.row_text(f, 1) =~ "?help" end)
    # The pane's title right island carries the first-visible/total
    # counter — never a mid-border island.
    assert Frame.row_text(frame, 1) =~ ~r/1\/\d+/

    # One wheel notch == one :down wherever the pointer sits — here over
    # the help box's body cells.
    send_event(runtime, %Event.Mouse{action: :scroll_down, button: nil, x: 40, y: 15})

    scrolled = await_frame(fn f -> Frame.row_text(f, 1) =~ ~r/2\/\d+/ end)
    assert Frame.row_text(scrolled, 1) =~ "?help"
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
    refute body_text(frame) =~ "¹engine"
    assert Frame.row_text(frame, 1) =~ "apply · #{@destination}"

    send_event(runtime, Event.resize(120, 40))

    # The resize event rides the screen's async event loop — wait for
    # the reflowed frame instead of trusting one drain.
    frame =
      await_frame(fn frame ->
        frame.width == 120
      end)

    assert frame.width == 120
    # The op survives the resize; the embedded screen re-laid itself out
    # to the body rect of the new size.
    assert Frame.row_text(frame, 1) =~ "apply · #{@destination}"
  end

  test "the run panel floats over the mirror at the second canonical size (80x20)" do
    runtime = start_shell()
    loaded_frame(runtime)
    send_text(runtime, "a")
    assert settled_frame(runtime) |> body_text() =~ "apply · #{@destination}"

    send_event(runtime, Event.resize(80, 20))
    frame =
      await_frame(fn frame ->
        frame.width == 80 and body_text(frame) =~ "apply · #{@destination}"
      end)

    # a -> gate -> typed verb: at 80x20 the body is 80x18 — past the
    # float threshold, so the done panel (56x7, centered) floats and the
    # dashboard mirror shows above it.
    send_text(runtime, "a")
    await_frame(fn f -> body_text(f) =~ "Confirm apply" end)
    "apply" |> String.graphemes() |> Enum.each(&send_text(runtime, &1))
    send_key(runtime, :enter)

    frame =
      await_frame(fn f ->
        body_text(f) =~ "Applied generation gen-3"
      end)

    assert body_text(frame) =~ "¹engine"
    assert body_text(frame) =~ "applied — the dashboard below is live again"
  end

  # -- helpers -----------------------------------------------------------------

  defp body_text(frame) do
    # The body spans rows 1..(height-1) — the dashboard owns the whole
    # terminal but the footer row — and the shell footer is the last row
    # (op mode's own footer included).
    1..(frame.height - 1)
    |> Enum.map(&Frame.row_text(frame, &1))
    |> Enum.join("\n")
  end

  # The full frame — footer included; body_text already covers the
  # loaded home's data rows, so this only differs by the footer row.
  defp full_text(frame) do
    1..frame.height
    |> Enum.map(&Frame.row_text(frame, &1))
    |> Enum.join("\n")
  end

  # 1-based row of the first BODY row containing `needle`. The footer
  # (last row) is chrome — every box title, data row and badge lives in
  # the body — so the search skips it; a needle that exists only on the
  # chrome row (keycap islands) is not found.
  defp find_row(frame, needle) do
    1..(frame.height - 1)
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
    row = Enum.find(1..(frame.height - 1), &String.contains?(Frame.row_text(frame, &1), "applied:"))
    assert row, "journal applied row not found on the home frame"
    row
  end

  ## -- in-box deep views (§1.6: drill/zoom never leave the dashboard) -----

  describe "the box drill (Proc::y+8: enter/click expand in place)" do
    test "enter expands the capabilities box into its tree drill; enter again restores" do
      runtime = start_shell()
      loaded_frame(runtime)

      send_key(runtime, :enter)
      frame = await_frame(fn f -> body_text(f) =~ " collapsed — right to drill" end)

      # The grown box hosts the browser's panes; the summary meters gave
      # way to the tree (buttonbar and rollup are the contracted view).
      assert body_text(frame) =~ "editor"
      refute body_text(frame) =~ "rollup:"
      refute body_text(frame) =~ "a apply"

      send_key(runtime, :enter)
      frame = await_frame(fn f -> body_text(f) =~ "rollup:" end)
      refute body_text(frame) =~ " collapsed — right to drill"
    end

    test "the tree drill lives inside the box: right expands the node, left collapses" do
      runtime = start_shell()
      loaded_frame(runtime)

      send_key(runtime, :enter)
      await_frame(fn f -> body_text(f) =~ " collapsed — right to drill" end)

      send_key(runtime, :right)
      frame = await_frame(fn f -> body_text(f) =~ "init.lua" or body_text(f) =~ "nvim" end)
      # Still the dashboard: the drill lives inside the box (no views).
      assert find_row(frame, "²capabilities")

      send_key(runtime, :left)
      await_frame(fn f -> body_text(f) =~ " collapsed — right to drill" end)
    end

    test "a click inside a zoomable box zooms it; the zoom owns every click until released" do
      runtime = start_shell()
      loaded_frame(runtime)

      # At 100x30 the stacked tiler puts diff fifth; click its body band
      # (row 21, well inside the box) — the zoom takes over the dashboard.
      send_event(runtime, %Event.Mouse{action: :press, button: :left, x: 50, y: 21})
      frame = await_frame(fn f -> Frame.row_text(f, 1) =~ "⁵diff" end)
      assert body_text(frame) =~ "workstation diff (core)"

      # The zoomed box IS the dashboard rect now: a click inside it is
      # the enter-again contract, wherever it lands.
      send_event(runtime, %Event.Mouse{action: :press, button: :left, x: 50, y: 3})
      frame = await_frame(fn f -> not (body_text(f) =~ "workstation diff (core)") end)
      refute Frame.row_text(frame, 1) =~ "⁵diff"
    end

    test "a click in another box never steals the capabilities drill" do
      runtime = start_shell()
      loaded_frame(runtime)

      send_key(runtime, :enter)
      frame = await_frame(fn f -> body_text(f) =~ " collapsed — right to drill" end)

      # Click a band BELOW the grown caps box (it now owns rows ~10-23;
      # plan sits beneath): the drill stays.
      send_event(runtime, %Event.Mouse{action: :press, button: :left, x: 50, y: 27})
      assert body_text(latest_frame()) =~ " collapsed — right to drill"

      # Click inside the caps box itself: the enter-again contract.
      send_event(runtime, %Event.Mouse{action: :press, button: :left, x: 50, y: 12})
      await_frame(fn f -> body_text(f) =~ "rollup:" end)
    end

    test "enter zooms the plan read when the capabilities box is hidden" do
      runtime = start_shell()
      loaded_frame(runtime)

      send_text(runtime, "2")
      await_frame(fn f -> not (body_text(f) =~ "²capabilities") end)

      send_key(runtime, :enter)
      frame = await_frame(fn f -> Frame.row_text(f, 1) =~ "⁴plan" end)
      # The zoom is the box's full render text in a scrollable pane.
      assert body_text(frame) =~ "workstation plan (core)"
      assert body_text(frame) =~ "generation : gen-3"
    end

    test "the zoomed read scrolls under the wheel (the pane owns the pointer)" do
      runtime = start_shell()
      loaded_frame(runtime)

      send_text(runtime, "2")
      send_key(runtime, :enter)
      frame = await_frame(fn f -> Frame.row_text(f, 1) =~ "⁴plan" end)

      # Shrink the window until the read outgrows its pane: the second
      # canonical size (80×24) clipped further — the overlay re-renders
      # from (state, dims) like every view.
      send_event(runtime, %Event.Resize{width: 80, height: 12})
      frame = await_frame(fn f -> f.width == 80 and Frame.row_text(f, 1) =~ "⁴plan" end)
      # The counter rides the title's right island on the top border.
      assert Frame.row_text(frame, 1) =~ ~r/1\/\d+/

      # The wheel rides the pane's scroll keys while it is focused.
      send_event(runtime, %Event.Mouse{action: :scroll_down, button: nil, x: 40, y: 6})
      scrolled = await_frame(fn f -> Frame.row_text(f, 1) =~ ~r/2\/\d+/ end)
      assert Frame.row_text(scrolled, 1) =~ "⁴plan"
    end
  end

  # -- gate regressions (wedge fixes) ---------------------------------------

  # The gate's portrait defect: at rows >= cols the dashboard booted but
  # the async wire data never landed (a stalled render inside the
  # border/island fitting). This pins the loaded home at the gate's
  # 60x50 shape: every stack box's read renders.
  describe "gate geometries" do
    test "the dashboard loads its wires at rows >= cols (60x50)" do
      start_screen!(Shell, rows: 60, cols: 50, screen_opts: shell_opts())

      frame =
        await_frame(fn frame ->
          text = body_text(frame)
          text =~ "9.9.9-test" and text =~ "rollup:"
        end)

      text = body_text(frame)

      # Engine identity + capabilities rollup (the loaded gate above)
      # plus deep rows from the plan and status reads (the 50-col stack
      # boxes carry summary rows, not zoomed targets).
      assert text =~ "linux-test"
      assert text =~ "gen-3"
      assert text =~ "entries:    3"
    end
  end
end
