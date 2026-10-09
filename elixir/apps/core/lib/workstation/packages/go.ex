defmodule Workstation.Packages.Go do
  @moduledoc """
  The `go` workstation package's native contribution:
  one managed launcher symlink into the self-unpacked toolchain root.

  The archive payload under `~/.local/opt/go` is provisioned outside
  engine-rendered source state (the toolchain bootstrap contract: exact tar
  unpack), so the link target stays a relative path inside the destination
  home.
  """

  @behaviour Workstation.Core.Catalog.Spec

  alias Workstation.Core.Catalog.Packages

  @spec spec() :: map()
  def spec do
    %{
      foundation: "foundation/runtime",
      id: "go",
      requires: ["foundation"],
      supported_hosts: nil,
      contributes: [
        Packages.chezmoi(target: ".local/bin/go", kind: :symlink, to: "../opt/go/bin/go")
      ]
    }
  end
end
