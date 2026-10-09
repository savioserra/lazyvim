defmodule Workstation.Core.Digest do
  @moduledoc """
  Layer: kernel. The kernel law: this module names no package, no backend and no
  consumer -- it speaks only contracts and shapes (docs/architecture.md,
  "Module hierarchy & moduledoc conventions").
  Byte digests shared by the plan pipeline. Lowercase hex, matching
  `vim.fn.sha256` so fingerprints, manifest digests and generation ids are
  byte-identical to the Lua engine's recorded values.
  """

  @spec sha256(binary()) :: String.t()
  def sha256(data) when is_binary(data), do: Base.encode16(:crypto.hash(:sha256, data), case: :lower)
end
