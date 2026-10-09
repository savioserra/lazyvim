defmodule Workstation.Core.Contracts.Discovery do
  @moduledoc """
  The shared discovery pipeline behind the three runtime Discover modules
  (`Workstation.Core.Catalog.Discover`, `Workstation.Core.Contracts.Provider.Discover`,
  `Workstation.Core.Contracts.Contract.Discover`).

  Discovery is deterministic, identical for every behaviour:

  * candidates are exactly the modules the loaded package tree declared
    (`Workstation.Core.Packages.Loader.ensure/0` walks it once per node) —
    a package is added by adding its directory, and a module outside the
    tree is structurally invisible to the package surfaces;
  * engine-owned effect contracts may additionally declare a code-path
    namespace (`:namespace`) — the domain-generic contracts live in the
    engine, and their ids publish through the same by_id surface;
  * conformance is validated before use: the behaviour attribute plus the
    full required callback set, each rejection naming the offending module.

  The parameterized shape (`%{behaviour:, callbacks:, label:}`) is the
  whole difference between the three callers — the machinery exists once,
  here, and the Discover modules delegate to it. Shared logic lives in a
  shared pure helper, never a copy.

  Layer: kernel. The kernel law: discovery is the package tree walk — the
  loader loads what the tree declares, conformance selects implementors,
  and the kernel names none of them. (implementor policy: the three
  Discover modules delegate with their parameterization; an implementor is
  whatever conforming behaviour module the package tree carries, never a
  hand-written registry.)
  """

  @typedoc "The one parameterization a Discover module supplies."
  @type spec :: %{
          required(:behaviour) => module(),
          required(:callbacks) => [{atom(), non_neg_integer()}],
          required(:label) => String.t(),
          optional(:namespace) => String.t()
        }

  @doc """
  The discovered, conformed, module-name-sorted implementor set for one
  discovery spec: every module the loaded package tree declared that
  implements `behaviour` and defines the full required `callbacks` set.
  """
  @spec modules(spec()) :: [module()]
  def modules(%{behaviour: behaviour, callbacks: callbacks, label: label} = spec) do
    # Packages are self-contained in the tree: the loader walks the tree
    # and loads its manifests (once per node), and the package surfaces'
    # candidate set IS what the tree declared — no code-path enumeration,
    # no namespace filter; a module outside the package tree is
    # structurally invisible.
    Workstation.Core.Packages.Loader.ensure()

    tree =
      Workstation.Core.Packages.Loader.module_list()
      |> Enum.map(&elem(&1, 0))

    # Engine-owned effect contracts declare a code-path namespace: their
    # ids publish through the same by_id surface as the tree's.
    code_path =
      if namespace = spec[:namespace] do
        :code.all_available()
        |> Enum.flat_map(&candidates/1)
        |> Enum.uniq()
        |> Enum.filter(&namespace?(&1, namespace))
        |> Enum.reject(&test_source?/1)
      else
        []
      end

    (tree ++ code_path)
    |> Enum.uniq()
    |> Enum.filter(&conforming?(&1, behaviour, callbacks, label))
    |> Enum.sort()
  end

  def modules(_other),
    do: raise(ArgumentError, "discovery requires behaviour, callbacks and label")

  # Test-tree exclusion: the beam's compile_info records the source path a
  # module was compiled from. The exclusion keys on the `test` path SEGMENT
  # being an ancestor of the recorded source file (remainder of the path
  # ends with the file's basename) — not a "/test/" substring hunt, which
  # silently misses relative recorded paths such as
  # "test/support/probe.ex". Deterministic in every environment, and a
  # no-op in releases where no test beams exist.
  defp test_source?(module) do
    case :code.which(module) do
      path when is_list(path) ->
        # One requested chunk comes back as {ok, {File, {Chunk, Data}}};
        # accept the list form too so the exclusion survives beam_lib
        # shape variations.
        info =
          case :beam_lib.chunks(path, [:compile_info]) do
            {:ok, {_file, {compile_info, info}}} when compile_info == :compile_info -> info
            {:ok, {_file, [{compile_info, info}]}} when compile_info == :compile_info -> info
            _ -> []
          end

        info |> Keyword.get(:source, []) |> List.to_string() |> test_tree_path?()

      _ ->
        false
    end
  end

  defp test_tree_path?(source) do
    segments = Path.split(source)

    case Enum.find_index(segments, &(&1 == "test")) do
      nil ->
        false

      index ->
        remainder = Enum.drop(segments, index + 1)
        # A path ENDING in a `test` file (no remainder) is not a test tree.
        remainder != [] and List.last(remainder) == Path.basename(source)
    end
  end

  # :code.all_available/0 returns {name, filename, loaded_path}; the name is
  # a charlist on OTP 28, a string on older OTP lines and an atom on some
  # intermediates — normalize to the module atom without loading the beam.
  defp candidates({name, _filename, _loaded_path}) when is_list(name),
    do: [List.to_atom(name)]

  defp candidates({name, _filename, _loaded_path}) when is_binary(name),
    do: [String.to_atom(name)]

  defp namespace?(module, namespace) when is_atom(module) do
    name = Atom.to_string(module)
    String.starts_with?(name, namespace) and name != namespace
  end

  # Test-tree exclusion for the code-path arm: the beam's compile_info
  # records the source path a module was compiled from, keyed on the
  # `test` path SEGMENT being an ancestor of the recorded source file.
  # The tree arm needs no exclusion — the walk never leaves `packages/`.
  defp test_source?(module) do
    case :code.which(module) do
      path when is_list(path) ->
        info =
          case :beam_lib.chunks(path, [:compile_info]) do
            {:ok, {_file, {compile_info, info}}} when compile_info == :compile_info -> info
            {:ok, {_file, [{compile_info, info}]}} when compile_info == :compile_info -> info
            _ -> []
          end

        info |> Keyword.get(:source, []) |> List.to_string() |> test_tree_path?()

      _ ->
        false
    end
  end

  defp test_tree_path?(source) do
    segments = Path.split(source)

    case Enum.find_index(segments, &(&1 == "test")) do
      nil ->
        false

      index ->
        remainder = Enum.drop(segments, index + 1)
        remainder != [] and List.last(remainder) == Path.basename(source)
    end
  end

  # Conformance: the module must be loadable, declare the behaviour and
  # define the full required callback set. A namespace module without the
  # behaviour is simply not an implementor; declaring the behaviour without
  # a required callback is a broken implementor and fails discovery with the
  # module named.
  defp conforming?(module, behaviour, callbacks, label) do
    case Code.ensure_loaded(module) do
      {:module, loaded} ->
        # module_info(:attributes) carries the @behaviour declarations; the
        # typed module_info(:behaviours) key is not in Elixir's accepted set.
        behaviours = loaded.module_info(:attributes) |> Keyword.get(:behaviour, [])

        if behaviour in behaviours do
          Enum.each(callbacks, fn {callback, arity} ->
            function_exported?(loaded, callback, arity) ||
              raise ArgumentError,
                    "#{inspect(loaded)} declares the #{label} behaviour but does not define #{callback}/#{arity}"
          end)

          true
        else
          false
        end

      {:error, _reason} ->
        # An unloadable namespace module is not an implementor; the compiler
        # owns loadability, and discovery never guesses past it.
        false
    end
  end
end
