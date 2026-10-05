defmodule Workstation.Core.Catalog.Packages.Foundation do
  @moduledoc """
  The `foundation` workstation package's native contribution:
  the catalog discipline root every HOME-writing capability depends on.

  The runtime payload archives (rg/fd/fzf/lazygit/tree-sitter/rainfrog) are
  not managed home targets and are no longer provisioned by the retired Lua
  `setup` handler; capability acquisition is bootstrap's contract. The
  native contribution surface is the shared-shell PATH fragment on the
  three startup files. Fragment bytes are load-bearing: they are
  generation-digested engine output (see `Workstation.Core.ShellProgram`).
  """

  @behaviour Workstation.Core.Catalog.Spec

  alias Workstation.Core.Catalog.Packages

  @startup_files [".profile", ".bashrc", ".zshrc"]

  @fragment %{
    id: "user-local-bin",
    order: 10,
    marker: "# chezmoi: managed user-local bin",
    body: "case \":$PATH:\" in *\":$HOME/.local/bin:\"*) ;; *) [ -d \"$HOME/.local/bin\" ] && PATH=\"$HOME/.local/bin:$PATH\" ;; esac"
  }

  @spec spec() :: map()
  def spec do
    %{
      foundation: "foundation/base",
      id: "foundation",
      requires: [],
      supported_hosts: nil,
      contributes: Enum.map(@startup_files, &Packages.shell(&1, @fragment))
    }
  end
end
