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
      "  1..4           toggle box (1 engine, 2 capabilities, 3 plan,",
      "                 4 status)",
      "  p / P          cycle layouts (full · audit · minimal)",
      "  enter          drill the focused box in place (capabilities tree,",
      "                 plan read zoom); enter again — or Esc — restores",
      "  click box      drill/zoom it",
      "  wheel          scroll the focused pane (zoom, help, browser cursor)",
      "  r              refresh the reads",
      "  ?              toggle this help",
      "  q              quit",
      "",
      "capabilities (in place)",
      "  ↑↓ move · → expand node · ← or backspace collapse · * marks a file that would change",
      "",
      "the write plane",
      "  mutation lives in the nix substrate: the workstation-switch drivers",
      "  (apply / rollback / update / sync) own every home and system change;",
      "  this dashboard is the resident read surface over the desired state.",
      "",
      "standalone entry points (for scripts; unchanged)",
      "  workstation status | plan | capabilities | json <command>",
      "  workstation system applied --generation N   (the switch receipt)",
      "",
      "bare `workstation` opens this app on a terminal; without a TTY it",
      "prints the verb help instead (never hangs, exit 0)."
    ]
  end
end
