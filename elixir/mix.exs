defmodule Workstation.Umbrella.MixProject do
  use Mix.Project

  @moduledoc """
  Umbrella root of the Workstation engine. Apps: `:core` (the pure engine —
  catalog, dependency graph, planning, canonical JSON; zero runtime deps),
  `:daemon` (Zoi strict wire schemas), `:cli`
  (optimus + term_ui front end). App dependencies are declared per app and
  hoisted into this lockfile; distribution ships one `mix release` per platform
  (no escript, ever).
  """

  def project do
    [
      apps_path: "apps",
      apps: [:core, :cli, :daemon],
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  # One release per platform: `workstation` (the CLI front end with the
  # daemon app's protocol modules and the core engine inside). No escript,
  # ever — the daemon and the TUI need the full OTP runtime, and escripts
  # cannot ship them.
  #
  # The release control script that `:assemble` writes to `bin/workstation`
  # is renamed to `bin/workstation_ctl` and replaced by a dispatcher with the
  # same name: `workstation` on PATH must be the product CLI (docs/elixir.md
  # §CLI), while OTP lifecycle access (start/stop/rpc/eval — used by the
  # daemon boot path and ops) stays available under `_ctl`. The dispatcher
  # forwards control verbs unchanged and boots the release VM for every CLI
  # verb, handing argv straight to `Workstation.CLI.Router.main/1`.
  defp releases do
    [
      workstation: [
        applications: [core: :permanent, daemon: :permanent, cli: :permanent],
        include_executables_for: [:unix],
        steps: [:assemble, &Workstation.Umbrella.MixProject.cli_dispatch_step/1]
      ]
    ]
  end

  @control_verbs ~w(start start_iex daemon daemon_iex eval rpc remote restart stop pid version)

  @doc false
  def cli_dispatch_step(%Mix.Release{} = release) do
    bin = Path.join(release.path, "bin")
    control = Path.join(bin, "workstation")
    File.rename!(control, Path.join(bin, "workstation_ctl"))

    File.write!(control, """
    #!/bin/sh
    set -eu
    dir=$(cd "$(dirname "$0")" && pwd)
    case "${1:-}" in
    #{Enum.map_join(@control_verbs, "|", &("  " <> &1))})
      exec "$dir/workstation_ctl" "$@" ;;
    *)
      exec "$dir/workstation_ctl" eval 'Workstation.CLI.Router.main(System.argv())' "$@" ;;
    esac
    """)

    File.chmod!(control, 0o755)
    release
  end

  defp deps do
    []
  end
end
