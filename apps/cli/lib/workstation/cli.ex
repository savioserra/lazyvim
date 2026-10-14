defmodule Workstation.CLI do
  @moduledoc """
  Workstation command-line front end. The read-only `status`/`plan`/`diff`
  surface evaluates the native live catalog in-process through the Elixir
  core (see `Workstation.CLI.Core`); `--input` substitutes a recorded
  golden envelope for offline replay. There is no second front end and no
  external engine process.
  """
end
