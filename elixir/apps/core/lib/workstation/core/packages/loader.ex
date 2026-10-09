defmodule Workstation.Core.Packages.Loader do
  @moduledoc """
  Layer: kernel. The kernel law: the loader knows the package tree root,
  never a package — it compiles and loads whatever manifest sources the
  tree carries into the running node, once per node, before any discovery
  scan; the namespace scan then sees them like any other implementor.

  Packages are self-contained: `workstation/packages/<id>/` carries its
  manifest (an Elixir module implementing the catalog-spec, capability-
  provider or effect-contract behaviours) beside its payloads, and id-path
  entries may be symlinks into the domain layout. The engine ships no
  package modules; loading the tree is the contract. Sources load in path
  order exactly once per node (a persistent mark keeps repeat discovery
  calls free), and a manifest that fails to compile fails discovery
  loudly, naming its path.
  """

  @mark {__MODULE__, :loaded}

  @doc """
  Load every manifest source under the package tree, once per node. A node
  that has already loaded the tree (or a tree with no manifest sources)
  is a no-op.
  """
  @spec ensure() :: :ok
  def ensure do
    unless :persistent_term.get(@mark, false) do
      root()
      |> then(&Path.wildcard(&1 <> "/**/*.ex"))
      # The tree may reach one manifest through an id-path symlink and its
      # real domain dir — dedupe by identity (inode), not by spelling.
      |> Enum.uniq_by(&File.stat!(&1).inode)
      |> Enum.sort()
      |> Enum.each(&Code.require_file/1)

      :persistent_term.put(@mark, true)
    end

    :ok
  end

  @doc "The package tree root: `<engine checkout>/packages`."
  @spec root() :: String.t()
  def root, do: Path.join([Workstation.Core.Update.engine_root([]), "packages"])
end
