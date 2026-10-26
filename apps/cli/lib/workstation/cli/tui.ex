defmodule Workstation.CLI.TUI do
  @moduledoc """
  Front door of the TUI (brief §3 b7).

  Scope is deliberately narrow: the bare-verb application shell
  (`Workstation.CLI.TUI.Shell`) is the one screen host — the standalone
  apply/update screens retired with the engine's write plane, and mutation
  lives in the nix substrate's workstation-switch drivers.

  Theme resolution is `Workstation.CLI.TUI.Theme.resolve/1` (the base token
  palette — the daemon overlay path retired with the daemon); the shell only
  ever sees resolved `#rrggbb` colors, because term_ui is a palette-layer
  consumer that cannot follow live OSC 4 retints (docs/theme.md).
  """

  alias TermUI.{ANSI, TerminalOutput}

  alias Workstation.CLI.TUI.Theme

  @doc """
  Run one screen module on the TTY backend.

  `:theme` may pin a resolved color map (tests inject the base palette to
  stay offline); otherwise it resolves from the base token palette.
  `:destination` rides through to screens that read the baked report.

  SGR mouse tracking (`?1000` + `?1006`) is enabled for the run and disabled
  in an after-clause: the pinned term_ui runtime never sends the sequences,
  so this front door owns the bracket. Without it terminals never emit mouse
  bytes; screens that do not route them ignore the events (`event_to_msg`
  catch-alls), and tests drive the Elm app directly without a TTY, so the
  writes never fire there.
  """
  @spec run(module(), keyword()) :: :ok | {:error, term()}
  def run(screen, opts) do
    theme =
      Keyword.get_lazy(opts, :theme, fn ->
        appearance = Keyword.get(opts, :appearance, :dark)
        Theme.resolve(appearance: appearance).colors
      end)

    TerminalOutput.write(ANSI.enable_mouse_tracking(:normal))
    TerminalOutput.write(ANSI.enable_sgr_mouse())

    try do
      TermUI.run(screen, Keyword.put(opts, :theme, theme))
    after
      TerminalOutput.write(ANSI.disable_sgr_mouse())
      TerminalOutput.write(ANSI.disable_mouse_tracking(:normal))
    end
  end
end
