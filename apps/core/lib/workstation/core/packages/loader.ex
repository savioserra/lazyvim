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
  reporting the modules the tree defined as `{module, defining source}`.
  `:error` when no engine checkout is anchored — resolution surfaces
  (behaviour dispatch by id) degrade to their code-path arm alone, because
  a bare host resolving a recorded envelope has no package tree to walk;
  the dispatch site then fails closed naming the unresolvable id. The
  native surfaces keep the hard law through `root/0`: package reads,
  data-manifest discovery and asset resolution raise, naming the missing
  checkout. A node that has already loaded the tree is a no-op.
  """
  @spec ensure() :: {:ok, [{module(), String.t()}]} | :error
  def ensure do
    if :persistent_term.get(@mark, false) do
      {:ok, :persistent_term.get(@modules, [])}
    else
      case safe_root() do
        :error ->
          :error

        root ->
          modules =
            root
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
          {:ok, modules}
      end
    end
  end

  @doc """
  The modules the loaded package tree defined, as `{module, defining
  source}` — discovery's only tree-arm candidate set. A module outside the
  package tree is not here, and nothing in the kernel names one: the walk is
  the entire package system.
  """
  @spec module_list() :: [{module(), String.t()}]
  def module_list, do: :persistent_term.get(@modules, [])

  @doc "The package tree root: `<engine checkout>/packages`."
  @spec root() :: String.t()
  def root, do: Path.join([Workstation.Core.Update.engine_root([]), "packages"])

  # The anchored-checkout probe behind the soft arm: `engine_root/1` raises
  # when nothing is anchored; here that absence is `:error`, not a crash.
  defp safe_root do
    root()
  rescue
    ArgumentError -> :error
  end

  defp to_module(module) when is_binary(module), do: String.to_atom(module)
  defp to_module(module) when is_atom(module), do: module
end
