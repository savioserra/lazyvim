defmodule Workstation.Core.Catalog.Discover do
  @moduledoc """
  Runtime package-spec discovery: the catalog is composed from whatever
  conforming provider modules the code path carries, never from a
  hand-written registration list.

  Provider contract (see `Workstation.Core.Catalog.Spec`): a module under
  the `Workstation.Core.Catalog.Packages.*` namespace that declares the
  behaviour and defines `spec/0`. Discovery is deterministic on three
  axes:

  * candidates come from `:code.all_available/0`, narrowed to the
    discovery namespace (package modules are compiled into the app either
    way; the namespace only keeps the loader from touching dependency
    beams) and sorted by module name — declaration order is not a thing;
  * `test/support` fixtures (and any module compiled from a test tree) are
    excluded deterministically by the beam's recorded source path, so test
    fixtures can never leak into the live catalog;
  * conformance is validated before use: the behaviour attribute, the
    `spec/0` export, spec shape (`Spec.validate!/2`) and duplicate package
    ids across distinct providers — each rejection names the offending
    module.
  """

  alias Workstation.Core.Catalog.Spec

  @namespace "Elixir.Workstation.Core.Catalog.Packages."

  @doc """
  The discovered provider modules, sorted by module name — the same order
  their ids sort in, which is the graph's tie-break, not a registration
  order.
  """
  @spec providers() :: [module()]
  def providers do
    :code.all_available()
    |> Enum.flat_map(&candidates/1)
    |> Enum.uniq()
    |> Enum.filter(&namespace?/1)
    |> Enum.reject(&test_source?/1)
    |> Enum.filter(&conforming?/1)
    |> Enum.sort()
  end

  @doc """
  The discovered packages: every provider's validated spec, in the same
  deterministic (module-name) order. Duplicate ids across distinct
  providers are rejected with both module names.
  """
  @spec specs() :: [map()]
  def specs do
    providers()
    |> Enum.map(fn module -> {module, module.spec()} end)
    |> tap(&validate_specs/1)
    |> Enum.map(fn {_module, spec} -> spec end)
  end

  # Shape + duplicate-id validation for a module->spec list; shared by
  # discovery and by direct tests of the rejection contract.
  @doc false
  @spec validate_specs([{module(), map()}]) :: :ok
  def validate_specs(pairs) do
    Enum.each(pairs, fn {module, spec} -> Spec.validate!(spec, module) end)

    declarers =
      Enum.reduce(pairs, %{}, fn {module, spec}, seen ->
        Map.update(seen, Map.fetch!(spec, :id), [module], &[module | &1])
      end)

    Enum.each(declarers, fn
      {_id, [_single]} -> :ok
      {id, modules} -> raise ArgumentError, "duplicate package id #{id} declared by #{inspect(Enum.reverse(modules))}"
    end)

    :ok
  end

  # :code.all_available/0 returns {name, filename, loaded_path}; the name is
  # a charlist on OTP 28, a string on older OTP lines and an atom on some
  # intermediates — normalize to the module atom without loading the beam.
  defp candidates({name, _filename, _loaded_path}) when is_list(name),
    do: [List.to_atom(name)]

  defp candidates({name, _filename, _loaded_path}) when is_binary(name),
    do: [String.to_atom(name)]

  defp namespace?(module) when is_atom(module) do
    name = Atom.to_string(module)
    String.starts_with?(name, @namespace) and name != @namespace
  end

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
        remainder != [] and Path.join(remainder) |> String.ends_with?(Path.basename(source))
    end
  end

  # Conformance: the module must be loadable, declare the behaviour and
  # define spec/0. A namespace module without the behaviour is simply not a
  # provider; declaring the behaviour without the callback is a broken
  # provider and fails discovery with the module named.
  defp conforming?(module) do
    case Code.ensure_loaded(module) do
      {:module, loaded} ->
        # module_info(:attributes) carries the @behaviour declarations; the
        # typed module_info(:behaviours) key is not in Elixir's accepted set.
        behaviours = loaded.module_info(:attributes) |> Keyword.get(:behaviour, [])

        if Spec in behaviours do
          function_exported?(loaded, :spec, 0) ||
            raise ArgumentError,
                  "#{inspect(loaded)} declares the package-spec behaviour but does not define spec/0"

          true
        else
          false
        end

      {:error, _reason} ->
        # An unloadable namespace module is not a provider; the compiler
        # owns loadability, and discovery never guesses past it.
        false
    end
  end
end
