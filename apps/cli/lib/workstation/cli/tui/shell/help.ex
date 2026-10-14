defmodule Workstation.CLI.TUI.Shell.Help do
  @moduledoc """
  The help reference's static key listing. Every key the shell and the
  embedded screens answer is listed here — the owner's directive makes
  documented keys part of each screen's contract, and this reference is
  the in-TUI place that contract lives (the `workstation` verb help still
  covers the plain verbs for non-TTY callers).
  """

  @doc "The help reference's lines (plain text, rendered as-is)."
  @spec lines() :: [String.t()]
  def lines do
    [
      "workstation — keys",
      "",
      "dashboard (the one screen)",
      "  1..6           toggle box (1 engine, 2 capabilities, 3 journal,",
      "                 4 plan, 5 diff, 6 status)",
      "  p / P          cycle layouts (full · audit · minimal)",
      "  enter          drill the focused box in place (capabilities tree,",
      "                 plan/diff read zoom); enter again — or Esc — restores",
      "  click box      drill/zoom it; click its strip island to toggle it off",
      "  wheel          scroll the focused pane (zoom, help, browser cursor)",
      "  r              refresh the reads",
      "  ?              toggle this help",
      "  q              quit (inside apply/update: leave the screen)",
      "",
      "home verbs (on the dashboard)",
      "  a              apply the current plan (opens the apply screen)",
      "  u              run the update flow (opens the update screen)",
      "",
      "capabilities (in place)",
      "  ↑↓ move · → expand node · ← or backspace collapse · * marks a file that would change",
      "",
      "apply · update (screens inside this app)",
      "  the screens document their keys on their border buttonbars; the",
      "  daemon is the only mutation engine — the screens are viewers over",
      "  its ops.",
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
