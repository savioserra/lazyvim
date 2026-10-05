defmodule Workstation.Daemon do
  @moduledoc """
  Resident daemon for hot-path commands. Owns the one frame codec and protocol
  (4-byte length-prefixed JSON, Zoi strict schemas, reject-by-default). The
  supervision tree is inert in CLI one-shot mode.
  """
end
