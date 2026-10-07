defmodule Workstation.CLI.TUI.ShellTest do
  # The shell runs under the same DeterministicBackend harness as the
  # apply/update screen tests: a real TermUI runtime, fixed `:load` /
  # `:check` / executor seams (no daemon, deterministic replay), frames
  # asserted row-by-row. Wire fixtures use the production shapes — the
  # status wire carries the package→foundation `taxonomy` map, plan
  # entries carry `attribution`, and the update.check verdict is
  # `{"status" => "behind", "local" => …, "remote" => …}`.
  use ExUnit.Case, async: true

  import Workstation.CLITest.TUI

  alias TermUI.{Event, Frame}
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

  defp shell_opts(extra) do
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

  defp start_shell(extra \\ []),
    do: start_screen!(Shell, rows: 30, cols: 100, screen_opts: shell_opts(extra))

  # Forces a deterministic redraw and drains: the quiet window (100ms)
  # resolves the instantly-answering seams before assertions read rows.
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

  # -- shell chrome ---------------------------------------------------------

  test "init renders the global chrome: header, numbered tab strip, footer keys" do
    start_shell()

    # Identity counters ride header row 2 once the status read lands.
    frame = await_frame(fn f -> Frame.row_text(f, 2) =~ "v9.9.9-test" end)

    # Brand island + destination on the header's first line, identity
    # counters (engine version · mode · journal gen/rev) on the second,
    # the double rule third; the strip is the buttonbar row below it.
    assert frame |> Frame.row_text(1) =~ "workstation"
    assert frame |> Frame.row_text(1) =~ @destination
    assert frame |> Frame.row_text(2) =~ "v9.9.9-test"
    assert frame |> Frame.row_text(2) =~ "test mode"
    assert frame |> Frame.row_text(2) =~ "gen 2 · rev 7"
    assert frame |> Frame.row_text(3) =~ "══"

    strip = Frame.row_text(frame, 4)
    assert strip =~ "1home"
    assert strip =~ "2capabilities"
    assert strip =~ "3status"
    assert strip =~ "4plan"
    assert strip =~ "5diff"
    assert strip =~ "6daemon"
    assert strip =~ "7help"
    assert frame |> Frame.row_text(30) =~ "1-7 tabs"
    assert frame |> Frame.row_text(30) =~ "r refresh"
    assert frame |> Frame.row_text(30) =~ "? help"
  end

  # -- btop grammar: slots pinned by frame cells -----------------------------

  test "tab strip renders the key in the shortcut slot, active accent, inactive dimmed" do
    runtime = start_shell()
    frame = settled_frame(runtime)

    # Buttonbar islands: `┘1home└┘2capabilities└…`. The connector reads
    # chrome, the digit rides the shortcut slot (dark base #bb9af7), the
    # active tab label rides the accent role (dark base #7aa2f7).
    assert Frame.cell(frame, 4, 1).char == "┘"
    assert Frame.cell(frame, 4, 2).char == "1"
    assert Frame.cell(frame, 4, 2).fg == {187, 154, 247}
    assert Frame.cell(frame, 4, 3).char == "h"
    assert Frame.cell(frame, 4, 3).fg == {122, 162, 247}

    # Inactive tabs ride the inactive role (dark base #565f89).
    assert Frame.cell(frame, 4, 9).char == "2"
    assert Frame.cell(frame, 4, 9).fg == {187, 154, 247}
    assert Frame.cell(frame, 4, 10).char == "c"
    assert Frame.cell(frame, 4, 10).fg == {86, 95, 137}
  end

  test "footer keeps frame keys only, key caps in the shortcut slot" do
    runtime = start_shell()
    send_text(runtime, "2")
    frame = settled_frame(runtime)

    footer = Frame.row_text(frame, 30)
    # btop buttonbar: each key rides its own island (┘key label└).
    assert footer =~ "┘1-7 tabs└"
    assert footer =~ "┘←→ switch└"
    assert footer =~ "┘r refresh└"
    assert footer =~ "┘? help└"
    assert footer =~ "┘q quit└"
    # The drill grammar moved to the browser border — the global footer
    # keeps frame keys only.
    refute footer =~ "expand"
    refute footer =~ "collapse"

    # Key caps glow in the shortcut slot (after the ┘ connector).
    assert Frame.cell(frame, 30, 1).char == "┘"
    assert Frame.cell(frame, 30, 2).fg == {187, 154, 247}
  end

  test "home lists every verb's surface once the reads land" do
    start_shell()

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
    # rides the header identity row; the button rides the home body.
    assert full_text(frame) =~ "update available"
    assert text =~ "u update"
  end

  # -- tabs and global keys -------------------------------------------------

  test "digit keys switch tabs; arrows wrap; ? toggles help and returns" do
    runtime = start_shell()
    loaded_frame(runtime)

    send_text(runtime, "3")
    assert await_frame(fn f -> body_text(f) =~ "workstation status (core)" end) |> body_text() =~
             "workstation status (core)"

    # ←→ walk the strip in order: status → plan → status.
    send_key(runtime, :right)
    assert await_frame(fn f -> body_text(f) =~ "workstation plan (core)" end) |> body_text() =~
             "workstation plan (core)"

    send_key(runtime, :left)
    assert await_frame(fn f -> body_text(f) =~ "workstation status (core)" end) |> body_text() =~
             "workstation status (core)"

    # Wrap backwards to the last tab (help): home → ← wraps to help. The
    # walk goes home by digit because the capabilities tab keeps ←/→ for
    # its own drill-down — arrows no longer cross it.
    send_text(runtime, "1")
    send_key(runtime, :left)
    assert await_frame(fn f -> body_text(f) =~ "workstation — keys" end) |> body_text() =~
             "workstation — keys"

    send_text(runtime, "?")
    # The restyled home no longer carries that identity line; the gate is
    # the header counters' version + the gone help title.
    frame =
      await_frame(fn f ->
        text = body_text(f)
        text =~ "9.9.9-test" and not (text =~ "workstation — keys")
      end)

    assert body_text(frame) =~ "9.9.9-test"
  end

  test "help tab documents keys and screens; scrolls to the bare-verb note" do
    runtime = start_shell()
    send_text(runtime, "7")
    text = await_frame(fn f -> body_text(f) =~ "workstation — keys" end) |> body_text()

    assert text =~ "workstation — keys"
    assert text =~ "1..7"
    assert text =~ "capabilities"
    assert text =~ "apply · update (screens inside this app)"

    # The help is longer than the pane: it scrolls (nothing clipped).
    send_key(runtime, :end)
    text = settled_frame(runtime) |> body_text()

    assert text =~ "standalone entry points"
    assert text =~ "--headless"
    assert text =~ "bare `workstation` opens this app on a terminal"
    assert text =~ "without a TTY"
    assert text =~ "keeps running daemon-side"
  end

  # -- read views: canonical Render text in a scrollable pane ---------------

  test "status tab renders the exact verb text (single source of truth)" do
    runtime = start_shell()
    send_text(runtime, "3")

    # The status read is a wire load — wait for the verb header instead
    # of trusting one drain to land after the answer.
    frame =
      await_frame(fn frame ->
        body_text(frame) =~ "workstation status (core)"
      end)

    text = body_text(frame)

    assert text =~ "workstation status (core)"
    assert text =~ "platform: linux-test"
    assert text =~ "packages: nvim, helix, tmux"
    assert text =~ "destination: #{@destination}"
    assert text =~ "journal: generation=2"
  end

  test "read failures split into the transport shape and other errors" do
    runtime =
      start_shell(load: loader(%{status: {:error, {"daemon_unavailable", "ENOENT"}}}))

    send_text(runtime, "3")
    text = settled_frame(runtime) |> body_text()
    assert text =~ "daemon unreachable"
    assert text =~ "daemon_unavailable"
    assert text =~ "workstation daemon"

    # r retries the read (the seam keeps failing; the error stays honest).
    send_text(runtime, "r")
    assert settled_frame(runtime) |> body_text() =~ "retry with r"
  end

  # -- capabilities browser -------------------------------------------------

  test "capabilities tab opens the domain-grouped browser with drill-down" do
    runtime = start_shell()
    send_text(runtime, "2")

    # The caps tab rides the WIRE LOAD seam (independent of the frame
    # seam) — match frames until the browser's domain rows render.
    frame =
      await_frame(fn frame ->
        text = body_text(frame)
        text =~ "▸ editor" and text =~ "▸ terminal"
      end)

    text = body_text(frame)
    assert text =~ "▸ editor — 2 packages · 2 files · 1 would change"
    # The mosaic halves the outline pane, so long rows clip at the box
    # edge — assert the clipped prefix in the drill pane.
    assert body_text(frame) =~ "▸ terminal — 1 packages · 1 files"
    # Top level is rollups — no raw file dump.
    refute text =~ ".config/nvim/init.lua"

    # Drill into editor → first package → files: enter toggles the row
    # under the cursor. Package order follows the envelope (helix sorts
    # before nvim).
    send_key(runtime, :enter)
    frame = settled_frame(runtime)
    assert body_text(frame) =~ "▾ editor"

    send_key(runtime, :down)
    send_key(runtime, :down)
    send_key(runtime, :enter)
    assert settled_frame(runtime) |> body_text() =~ ".config/nvim/init.lua"

    # ← collapses the package under the cursor AND STAYS on the tab: on
    # the capabilities tab the arrows drill instead of switching tabs,
    # so the strip still shows capabilities active and the browser frame
    # (not another tab's) loses the file rows.
    send_key(runtime, :left)
    frame = settled_frame(runtime)
    assert Frame.row_text(frame, 4) =~ "2capabilities"
    assert body_text(frame) =~ "▾ editor"
    refute body_text(frame) =~ ".config/nvim/init.lua"

    # backspace pops the remaining drill level (the editor domain) back
    # to rollups; → re-expands it (enter's toggle twin).
    send_key(runtime, :up)
    send_key(runtime, :up)
    send_key(runtime, :backspace)
    frame = settled_frame(runtime)
    assert body_text(frame) =~ "▸ editor — 2 packages"
    refute body_text(frame) =~ "▾ editor"

    send_key(runtime, :right)
    assert settled_frame(runtime) |> body_text() =~ "▾ editor"
  end

  test "capabilities loading state names the missing wire" do
    runtime =
      start_shell(
        load:
          loader(%{
            plan: fn ->
              Process.sleep(400)
              {:ok, plan_wire()}
            end
          })
      )

    send_text(runtime, "2")
    send_event(runtime, Event.resize(100, 30))
    assert latest_frame() |> body_text() =~ "loading plan"

    # The seam lands asynchronously; ride the draws until the browser
    # replaces the loading state (bounded — no magic sleep).
    await_frame(fn frame -> body_text(frame) =~ "▸ editor — 2 packages" end)
  end

  # -- embedded apply / update screens ---------------------------------------

  test "a opens the apply screen INSIDE the app (op pseudo-tab in the strip)" do
    runtime = start_shell()
    # Settle first: `a` needs the plan wire loaded (the key would race
    # the initial async loads otherwise).
    loaded_frame(runtime)
    send_text(runtime, "a")
    frame = await_frame(fn f -> body_text(f) =~ "apply · #{@destination}" end)

    assert Frame.row_text(frame, 4) =~ "8apply"
    text = body_text(frame)
    assert text =~ "apply · #{@destination}"
    assert text =~ "gen gen-3"
    assert text =~ "3 changes"
    # The screen's own footer is the last body row (no shell footer in
    # op mode — the shell keeps only header + strip above the screen).
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
    assert Frame.row_text(frame, 4) =~ "8update"
    assert body_text(frame) =~ "update · #{@destination}"
  end

  test "q inside an op screen returns home and re-reads (daemon keeps running)" do
    runtime = start_shell()
    loaded_frame(runtime)
    send_text(runtime, "a")
    assert await_frame(fn f -> body_text(f) =~ "apply · #{@destination}" end) |> body_text() =~
             "apply · #{@destination}"

    send_text(runtime, "q")
    frame = await_frame(fn f -> Frame.row_text(f, 4) =~ "1home" end)
    assert Frame.row_text(frame, 4) =~ "1home"
    assert body_text(frame) =~ "9.9.9-test"
    refute Frame.row_text(frame, 4) =~ "8apply"
  end

  test "u on home opens the update screen when the probe found updates" do
    runtime = start_shell()
    # `u` needs the shell's availability probe verdict — await the hint
    # (it rides the header identity row, not the body).
    await_frame(fn frame -> full_text(frame) =~ "update available" end)
    send_text(runtime, "u")
    frame = settled_frame(runtime)

    assert Frame.row_text(frame, 4) =~ "8update"
    assert body_text(frame) =~ "update · #{@destination}"
  end

  test "q on a data tab quits the app (the footer's documented quit key)" do
    runtime = start_shell()
    loaded_frame(runtime)
    send_text(runtime, "3")
    settled_frame(runtime)

    send_text(runtime, "q")
    snapshot = shutdown_snapshot()
    assert snapshot.shutdown_reason == :normal
  end

  test "up-to-date probe: no hint row and u on home is a no-op" do
    runtime = start_shell(check: fn -> {:ok, %{"status" => "up_to_date"}} end)
    frame = settled_frame(runtime)

    refute body_text(frame) =~ "update available"

    send_text(runtime, "u")
    frame = settled_frame(runtime)
    assert Frame.row_text(frame, 4) =~ "1home"
    refute body_text(frame) =~ "update available"
  end

  # -- daemon tab ------------------------------------------------------------

  test "daemon tab reports health from the live status probe" do
    runtime = start_shell()
    send_text(runtime, "6")
    frame = settled_frame(runtime)

    # The tab is a two-box mosaic; the liveness box titles itself with
    # the daemon badge and carries the re-probe button on its border.
    assert Frame.row_text(frame, 5) =~ "daemon"
    text = body_text(frame)

    assert text =~ "reachable"
    assert text =~ "workstation 9.9.9-test"
    assert Frame.row_text(frame, 29) =~ "r re-probe"
  end

  test "daemon tab shows the recovery shape when the daemon is unreachable" do
    runtime =
      start_shell(load: loader(%{status: {:error, {"daemon_unavailable", "ENOENT"}}}))

    send_text(runtime, "6")

    # The daemon probe rides its own async seam (probing → unreachable).
    frame =
      await_frame(fn frame ->
        body_text(frame) =~ "unreachable"
      end)

    text = body_text(frame)

    assert text =~ "unreachable"
    assert text =~ "workstation daemon"
  end

  # -- btop grammar: borders, ramps, per-domain accents ----------------------

  @tag :btop_browser
  test "capabilities browser carries its action bar on the border with a cursor counter" do
    runtime = start_shell()
    send_text(runtime, "2")

    # The fixture wires answer instantly, so the first capabilities frame
    # is usually already the loaded mosaic — pin the whole anatomy on ONE
    # awaited frame (title island + the collapsed drill hint) instead of
    # re-awaiting content that may never be redrawn.
    frame =
      await_frame(fn f ->
        Frame.row_text(f, 5) =~ "capabilities" and
          body_text(f) =~ "collapsed — enter to drill"
      end)

    # The box titles itself; the bottom border is the drill grammar with
    # the cursor position counter. The mosaic body starts under the
    # 3-row header + strip (rows 1-4), so the title island rides row 5.
    assert Frame.row_text(frame, 5) =~ "capabilities"
    # The drill pane's bottom border carries the cursor counter; the
    # inspector pane below it carries the action-bar buttons.
    drill_bottom = Frame.row_text(frame, 23)
    assert drill_bottom =~ "1/2"

    # The cursor renders as the selected bg+fg pair (never color-alone).
    # Data rows start at frame row 6 (inside the border).
    selected = Frame.cell(frame, 6, 2)
    assert selected.bg == {41, 46, 66}
    assert selected.fg == {192, 202, 245}

    # Drill into editor → nvim package → its planned file row reads warn
    # (would-change), and the counter follows the grown outline. The
    # drill pane lists the active domain's subtree (packages + drilled
    # files, the domain row itself rides the border title): rows 6-8 are
    # helix, nvim, the init.lua file (tmux belongs to the terminal
    # domain); the flat cursor sits on nvim. The panes split the body
    # 40/60, so the drill pane's content starts at column 42 (left box
    # cols 1-40, right border col 41).
    send_key(runtime, :enter)
    settled_frame(runtime)
    send_key(runtime, :down)
    send_key(runtime, :down)
    send_key(runtime, :enter)
    frame = settled_frame(runtime)

    assert Frame.row_text(frame, 8) =~ ".config/nvim/init.lua"
    assert Frame.cell(frame, 8, 42).fg == {224, 175, 104}
    assert Frame.row_text(frame, 23) =~ "2/3"

    # Moving the cursor onto the planned row swaps warn for the pair.
    send_key(runtime, :down)
    frame = settled_frame(runtime)
    selected = Frame.cell(frame, 8, 42)
    assert selected.bg == {41, 46, 66}
    assert selected.fg == {192, 202, 245}
  end

  test "plan pane titles its border with the scroll/refresh action bar and a position counter" do
    runtime = start_shell()
    send_text(runtime, "4")

    # Await the plan pane itself: a settled drain can predate the tab
    # switch render under parallel suite load (the mosaic's home row 5
    # is the engine box, so the plan title discriminates the tabs).
    frame = await_frame(fn frame -> Frame.row_text(frame, 5) =~ "plan" end)

    assert Frame.row_text(frame, 5) =~ "plan"
    bottom = Frame.row_text(frame, 29)
    assert bottom =~ "┘↑↓ scroll└"
    assert bottom =~ "┘r refresh└"
    assert bottom =~ ~r/1\/\d+/

    # Key caps in the shortcut slot: ┰ + ┘ connector put ↑ at column 3.
    assert Frame.cell(frame, 29, 3).char == "↑"
    assert Frame.cell(frame, 29, 3).fg == {187, 154, 247}
  end

  test "journal line rides the magnitude ramp by applied-at age (fresh/aging/stale)" do
    # The journal box's applied row sits wherever the responsive home puts
    # the box (2x2 mosaic at >=110 cols, the priority stack below), so the
    # row is located by its label instead of a pinned row number.
    ramp_cell = fn now ->
      _runtime = start_shell(now: now)
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

  test "daemon tab tints reachable state accent and unreachable err" do
    runtime = start_shell()
    settled_frame(runtime)
    send_text(runtime, "6")

    frame =
      await_frame(fn frame ->
        text = Frame.row_text(frame, 6)
        text =~ "state:" and text =~ "reachable"
      end)

    assert Frame.cell(frame, 6, value_col(frame, 6, "state")).fg == {122, 162, 247}

    runtime = start_shell(load: loader(%{status: {:error, {"daemon_unavailable", "ENOENT"}}}))

    # The error loader means the home never shows the engine identity —
    # the readiness gate is the daemon badge's unreachable verdict.
    await_frame(fn frame -> body_text(frame) =~ "● unreachable" end)
    send_text(runtime, "6")

    frame =
      await_frame(fn frame ->
        text = Frame.row_text(frame, 6)
        text =~ "state:" and text =~ "unreachable"
      end)

    assert Frame.cell(frame, 6, value_col(frame, 6, "state")).fg == {247, 118, 142}
  end

  test "read failures render in the err slot" do
    runtime = start_shell(load: loader(%{status: {:error, {"plan_stale", "nope"}}}))

    send_text(runtime, "3")

    # The status read fails ASYNC through the load seam — match every
    # arriving frame for the err-tinted failure row instead of trusting
    # one settled drain to land after the wire answer.
    frame =
      await_frame(fn frame ->
        row = find_row(frame, "read failed")
        row > 4 and fg_in_row?(frame, row, {247, 118, 142})
      end)

    row = find_row(frame, "read failed")
    assert row > 4
    assert fg_in_row?(frame, row, {247, 118, 142})
  end

  # -- resize ----------------------------------------------------------------

  test "resize reflows the chrome and the embedded screen" do
    runtime = start_shell()
    loaded_frame(runtime)
    send_text(runtime, "a")
    frame = settled_frame(runtime)
    assert Frame.row_text(frame, 4) =~ "8apply"
    assert Frame.row_text(frame, 5) =~ "apply · #{@destination}"

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
    assert Frame.row_text(frame, 5) =~ "apply · #{@destination}"
  end

  # -- helpers -----------------------------------------------------------------

  defp body_text(frame) do
    5..(frame.height - 1)
    |> Enum.map(&Frame.row_text(frame, &1))
    |> Enum.join("\n")
  end

  # The full frame — header included. The header identity row carries the
  # engine version and the update-availability hint, which body_text
  # (body only) never sees.
  defp full_text(frame) do
    1..frame.height
    |> Enum.map(&Frame.row_text(frame, &1))
    |> Enum.join("\n")
  end

  defp find_row(frame, needle) do
    1..frame.height
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
    row = Enum.find(5..(frame.height - 1), &String.contains?(Frame.row_text(frame, &1), "applied:"))
    assert row, "journal applied row not found on the home frame"
    row
  end
end
