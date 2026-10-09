defmodule Workstation.Core.Packages.Loader do
  @moduledoc """
  Layer: kernel. The kernel law: the loader knows the package tree root,
  never a package — it walks the tree, compiles and loads whatever manifest
  sources it carries into the running node, once per node, and records them;
  discovery's candidate set is exactly what the tree declared.

  Packages are self-contained: `workstation/packages/<id>/` carries its
  manifest (an Elixir module implementing the catalog-spec, capability-
  provider or effect-contract behaviours) beside its payloads, and id-path
  entries may be symlinks into the domain layout. The engine ships no
  package modules; loading the tree is the contract. Sources load in path
  order exactly once per node, and a manifest that fails to compile fails
  discovery loudly, naming its path.
  """

  @mark {__MODULE__, :loaded}
  @modules {__MODULE__, :modules}

  @doc """
  Walk the package tree and load every manifest source, once per node,
  recording the modules the tree defined. A node that has already loaded
  the tree (or a tree with no manifest sources) is a no-op.
  """
  @spec ensure() :: :ok
  def ensure do
    unless :persistent_term.get(@mark, false) do
      modules =
        root()
        |> then(&Path.wildcard(&1 <> "/**/*.ex"))
        |> Enum.uniq_by(&File.stat!(&1).inode)
        |> Enum.sort()
        |> Enum.flat_map(fn path ->
          path
          |> Code.require_file()
          |> Kernel.||([])
          |> Enum.map(fn {module, _binary} -> {to_module(module), path} end)
        end)

      :persistent_term.put(@modules, modules)
      :persistent_term.put(@mark, true)
    end

    :ok
  end

  @doc """
  The modules the loaded package tree defined, as `{module, defining
  source}` — discovery's only candidate set. A module outside the package
  tree is not here, and nothing in the kernel names one: the walk is the
  entire package system.
  """
  @spec module_list() :: [{module(), String.t()}]
  def module_list, do: :persistent_term.get(@modules, [])

  @doc "The package tree root: `<engine checkout>/packages`."
  @spec root() :: String.t()
  def root, do: Path.join([Workstation.Core.Update.engine_root([]), "packages"])

  defp to_module(module) when is_binary(module), do: String.to_atom(module)
  defp to_module(module) when is_atom(module), do: module
end
