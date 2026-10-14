defmodule Workstation.Core.Digest do
  @moduledoc """
  Layer: kernel. The kernel law: this module names no package, no backend and no
  consumer -- it speaks only contracts and shapes (docs/architecture.md,
  "Module hierarchy & moduledoc conventions").
  Byte digests shared by the plan pipeline. Lowercase hex — fingerprints,
  manifest digests and generation ids are content addresses over recorded
  bytes, and the goldens pin those bytes, so the digest form is stable
  across refactors.
  """

  @spec sha256(binary()) :: String.t()
  def sha256(data) when is_binary(data), do: Base.encode16(:crypto.hash(:sha256, data), case: :lower)
end
