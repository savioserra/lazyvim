defmodule Workstation.CLI.TUI do
  @moduledoc """
  Front door of the apply/update TUI screens (brief §3 b7).

  Scope is deliberately narrow: only `apply` and `update` ever run as a TUI —
  every other CLI surface stays plain. A screen receives an already-computed
  plan wire (the `Workstation.CLI.Core.evaluate/3` shape) and an `:executor`
  callback; production runs wire `Workstation.CLI.TUI.Executor` (the daemon-
  orchestrated path, b8), while an unconfigured screen still renders and
  confirms on the pure dry-run stand-in with no mutation path at all. That
  strangler seam keeps the interactive shell honest: the screens' contract
  does not churn when the engine applier graduates.

  Theme resolution is `Workstation.CLI.TUI.Theme.resolve/1` (daemon overlay
  when the destination has a live daemon, else the base token palette); the
  screens themselves only ever see resolved `#rrggbb` colors, because
  term_ui is a palette-layer consumer that cannot follow live OSC 4 retints
  (docs/theme.md).
  """

  alias Workstation.CLI.TUI.Theme

  @doc """
  Run one screen module on the TTY backend.

  `:theme` may pin a resolved color map (tests inject the base palette to
  stay offline); otherwise it is resolved from the destination home's daemon
  with the base palette fallback. `:destination` is required for resolution.
  """
  @spec run(module(), keyword()) :: :ok | {:error, term()}
  def run(screen, opts) do
    theme =
      Keyword.get_lazy(opts, :theme, fn ->
        home = Keyword.fetch!(opts, :destination)
        appearance = Keyword.get(opts, :appearance, :dark)
        Theme.resolve(home: home, appearance: appearance).colors
      end)

    TermUI.run(screen, Keyword.put(opts, :theme, theme))
  end
end
