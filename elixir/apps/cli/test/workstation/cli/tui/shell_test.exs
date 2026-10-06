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

  # -- shell chrome ---------------------------------------------------------

  test "init renders the global chrome: header, numbered tab strip, footer keys" do
    runtime = start_shell()
    frame = settled_frame(runtime)

    assert frame |> Frame.row_text(1) =~ "workstation — #{@destination}"
    strip = Frame.row_text(frame, 2)
    assert strip =~ "1 home"
    assert strip =~ "2 capabilities"
    assert strip =~ "3 status"
    assert strip =~ "4 plan"
    assert strip =~ "5 diff"
    assert strip =~ "6 daemon"
    assert strip =~ "7 help"
    assert frame |> Frame.row_text(30) =~ "1-7 tabs"
    assert frame |> Frame.row_text(30) =~ "r refresh"
    assert frame |> Frame.row_text(30) =~ "? help"
  end

  test "home lists every verb's surface once the reads land" do
    runtime = start_shell()
    frame = settled_frame(runtime)
    text = body_text(frame)

    assert text =~ "engine: workstation 9.9.9-test"
    assert text =~ "journal: generation 2"
    assert text =~ "plan: generation gen-3 · 3 entries · 0 removals"
    assert text =~ "diff: 1 pending change(s)"
    # editor (nvim+helix: 2 files) + terminal (tmux: 1 file) = 2 domains.
    assert text =~ "capabilities: 2 domains · 3 files · 2 would change"
    assert text =~ "daemon: reachable"
    assert text =~ "a apply"
    # The probe says an update exists → the home affordance shows.
    assert text =~ "update available"
    assert text =~ "u update"
  end

  # -- tabs and global keys -------------------------------------------------

  test "digit keys switch tabs; arrows wrap; ? toggles help and returns" do
    runtime = start_shell()

    send_text(runtime, "3")
    assert settled_frame(runtime) |> body_text() =~ "workstation status (core)"

    # ←→ walk the strip in order: status → plan → status.
    send_key(runtime, :right)
    assert settled_frame(runtime) |> body_text() =~ "workstation plan (core)"

    send_key(runtime, :left)
    assert settled_frame(runtime) |> body_text() =~ "workstation status (core)"

    # Wrap backwards to the last tab (help): home → ← wraps to help. The
    # walk goes home by digit because the capabilities tab keeps ←/→ for
    # its own drill-down — arrows no longer cross it.
    send_text(runtime, "1")
    send_key(runtime, :left)
    assert settled_frame(runtime) |> body_text() =~ "workstation — keys"

    send_text(runtime, "?")
    assert settled_frame(runtime) |> body_text() =~ "engine: workstation 9.9.9-test"
  end

  test "help tab documents keys and screens; scrolls to the bare-verb note" do
    runtime = start_shell()
    send_text(runtime, "7")
    frame = settled_frame(runtime)
    text = body_text(frame)

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
    text = settled_frame(runtime) |> body_text()

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
    frame = settled_frame(runtime)

    text = body_text(frame)
    assert text =~ "▸ editor — 2 packages · 2 files · 1 would change"
    assert text =~ "▸ terminal — 1 packages · 1 files · 1 would change"
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
    assert Frame.row_text(frame, 2) =~ "2 capabilities"
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

    # Let the seam land; the browser replaces the loading state.
    Process.sleep(400)
    assert settled_frame(runtime) |> body_text() =~ "▸ editor — 2 packages"
  end

  # -- embedded apply / update screens ---------------------------------------

  test "a opens the apply screen INSIDE the app (op pseudo-tab in the strip)" do
    runtime = start_shell()
    # Settle first: `a` needs the plan wire loaded (the key would race
    # the initial async loads otherwise).
    settled_frame(runtime)
    send_text(runtime, "a")
    frame = settled_frame(runtime)

    assert Frame.row_text(frame, 2) =~ "8 apply"
    text = body_text(frame)
    assert text =~ "workstation apply"
    assert text =~ "generation gen-3"
    # The screen's own footer is the last body row (no shell footer in
    # op mode — the shell keeps only header + strip above the screen).
    assert Frame.row_text(frame, 30) =~ "a confirm"
  end

  test "embedded apply run completes, then [u] swaps to the update screen" do
    runtime = start_shell()
    settled_frame(runtime)
    send_text(runtime, "a")
    assert settled_frame(runtime) |> body_text() =~ "workstation apply"

    # a opens the confirm dialog; y runs. The dialog footer documents
    # the keys on the screen's own footer row.
    send_text(runtime, "a")
    assert settled_frame(runtime) |> body_text() =~ "Confirm apply"
    assert Frame.row_text(settled_frame(runtime), 30) =~ "y confirm apply"
    send_text(runtime, "y")
    assert settled_frame(runtime) |> body_text() =~ "Applied generation gen-3"

    # The screen's own [u] handoff — now it swaps screens, not processes.
    send_text(runtime, "u")
    frame = settled_frame(runtime)
    assert Frame.row_text(frame, 2) =~ "8 update"
    assert body_text(frame) =~ "workstation update"
  end

  test "q inside an op screen returns home and re-reads (daemon keeps running)" do
    runtime = start_shell()
    settled_frame(runtime)
    send_text(runtime, "a")
    assert settled_frame(runtime) |> body_text() =~ "workstation apply"

    send_text(runtime, "q")
    frame = settled_frame(runtime)
    assert Frame.row_text(frame, 2) =~ "1 home"
    assert body_text(frame) =~ "engine: workstation 9.9.9-test"
    refute Frame.row_text(frame, 2) =~ "8 apply"
  end

  test "u on home opens the update screen when the probe found updates" do
    runtime = start_shell()
    # Settle first: `u` needs the shell's availability probe verdict.
    settled_frame(runtime)
    send_text(runtime, "u")
    frame = settled_frame(runtime)

    assert Frame.row_text(frame, 2) =~ "8 update"
    assert body_text(frame) =~ "workstation update"
  end

  test "q on a data tab quits the app (the footer's documented quit key)" do
    runtime = start_shell()
    settled_frame(runtime)
    send_text(runtime, "3")
    settled_frame(runtime)

    send_text(runtime, "q")
    snapshot = shutdown_snapshot()
    assert snapshot.shutdown_reason == :normal
  end

  test "up-to-date probe: no hint line and u on home is a no-op" do
    runtime = start_shell(check: fn -> {:ok, %{"status" => "up_to_date"}} end)
    frame = settled_frame(runtime)

    refute body_text(frame) =~ "update available"
    refute Frame.row_text(frame, 2) =~ "8 update"

    send_text(runtime, "u")
    assert settled_frame(runtime) |> Frame.row_text(2) =~ "1 home"
  end

  # -- daemon tab ------------------------------------------------------------

  test "daemon tab reports health from the live status probe" do
    runtime = start_shell()
    send_text(runtime, "6")
    text = settled_frame(runtime) |> body_text()

    assert text =~ "daemon health"
    assert text =~ "reachable"
    assert text =~ "workstation 9.9.9-test"
    assert text =~ "r re-probe"
  end

  test "daemon tab shows the recovery shape when the daemon is unreachable" do
    runtime =
      start_shell(load: loader(%{status: {:error, {"daemon_unavailable", "ENOENT"}}}))

    send_text(runtime, "6")
    text = settled_frame(runtime) |> body_text()

    assert text =~ "unreachable"
    assert text =~ "workstation daemon"
  end

  # -- resize ----------------------------------------------------------------

  test "resize reflows the chrome and the embedded screen" do
    runtime = start_shell()
    settled_frame(runtime)
    send_text(runtime, "a")
    frame = settled_frame(runtime)
    assert Frame.row_text(frame, 2) =~ "8 apply"
    assert Frame.row_text(frame, 3) =~ "workstation apply"

    send_event(runtime, Event.resize(120, 40))
    frame = latest_frame()

    assert frame.width == 120
    # The op survives the resize; the embedded screen re-laid itself out
    # to the body rect of the new size (its header rides under the shell
    # chrome).
    assert Frame.row_text(frame, 3) =~ "workstation apply"
  end

  # -- helpers -----------------------------------------------------------------

  defp body_text(frame) do
    3..(frame.height - 1)
    |> Enum.map(&Frame.row_text(frame, &1))
    |> Enum.join("\n")
  end
end
