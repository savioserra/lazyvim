defmodule Workstation.CLI.TUI.Shell.Help do
  @moduledoc """
  The help tab's static key reference. Every key the shell and the
  embedded screens answer is listed here — the owner's directive makes
  documented keys part of each screen's contract, and this tab is the
  in-TUI place that contract lives (the `workstation` verb help still
  covers the plain verbs for non-TTY callers).
  """

  @doc "The help tab's lines (plain text, rendered as-is)."
  @spec lines() :: [String.t()]
  def lines do
    [
      "workstation — keys",
      "",
      "tabs",
      "  1..7 · ←→     switch tab (home, capabilities, status, plan, diff, daemon, help)",
      "  r              refresh this tab's reads",
      "  ?              toggle help",
      "  q              quit (inside apply/update: leave the screen)",
      "",
      "home",
      "  a              apply the current plan (opens the apply screen)",
      "  u              run the update flow (opens the update screen)",
      "",
      "capabilities",
      "  ↑↓ move · enter/→ expand · ← collapse · * marks a file that would change",
      "",
      "status · plan · diff",
      "  ↑↓ / pgup/pgdn scroll · home/end jump",
      "",
      "daemon",
      "  r              re-probe the daemon (a read, never a mutation)",
      "",
      "apply · update (screens inside this app)",
      "  the screens document their own keys in their footers; the daemon is",
      "  the only mutation engine — the screens are viewers over its ops.",
      "  a running op keeps running daemon-side — leaving a screen never",
      "  cancels it.",
      "",
      "standalone entry points (for scripts; unchanged)",
      "  workstation apply [--headless] · workstation update [--headless]",
      "  workstation status | plan | diff | capabilities | json <command>",
      "",
      "bare `workstation` opens this app on a terminal; without a TTY it",
      "prints the verb help instead (never hangs, exit 0)."
    ]
  end
end
