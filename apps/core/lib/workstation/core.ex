defmodule Workstation.Core do
  @moduledoc """
  The workstation engine core: the declared-state report reader
  (`Workstation.Core.Report`), engine state and the guarded home reads
  (`Workstation.Core.EngineState`), the theme platform
  (`Workstation.Core.Theme.*`), canonical JSON encoding/decoding and the
  content digest. Pure and deterministic — data in, data out; zero runtime
  dependencies by contract; anything IO-bound or stateful lives outside
  this app. The declared state is the capability modules' report baked
  into the release; the core speaks shapes, never consumers.
  """
end
