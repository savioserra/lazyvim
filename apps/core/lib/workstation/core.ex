defmodule Workstation.Core do
  @moduledoc """
  The workstation engine core: catalog loading, dependency-graph ordering,
  source planning, canonical JSON encoding, source-name encoding, and journal
  reads. Pure and deterministic — data in, data out; zero runtime dependencies
  by contract; anything IO-bound or stateful lives outside this app.
  """
end
