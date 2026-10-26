defmodule Workstation.CLI do
  @moduledoc """
  Workstation command-line front end. The read-only `status`/`plan`/
  `capabilities` surface evaluates the baked declared-state report
  in-process (`Workstation.CLI.Output` — the flake's eval-report fold
  cached into the release); the bare verb is the TUI dashboard over the
  same reads. There is no second front end, no socket, and no resident
  engine process.
  """
end
