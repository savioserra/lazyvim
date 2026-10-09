defmodule Workstation.Core.Contracts.Discovery do
  @moduledoc """
  The shared discovery pipeline behind the three runtime Discover modules
  (`Workstation.Core.Catalog.Discover`, `Workstation.Core.Contracts.Provider.Discover`,
  `Workstation.Core.Contracts.Contract.Discover`).

  Discovery is deterministic on three axes, identical for every behaviour:

  * candidates come from `:code.all_available/0`, narrowed to the
    discovery namespace, and the result is sorted by module name —
    declaration order is not a thing;
  * test-tree beams are excluded deterministically by the beam's recorded
    source path, so test fixtures can never leak into a live set;
  * conformance is validated before use: the behaviour attribute plus the
    full required callback set, each rejection naming the offending module.

  The parameterized shape (`%{namespace:, behaviour:, callbacks:, label:}`)
  is the whole difference between the three callers — the machinery exists
  once, here, and the Discover modules delegate to it. Shared logic lives
  in a shared pure helper, never a copy.

  Layer: kernel. The kernel law: discovery is one deterministic scan of the
  code path — candidates, namespace, test-tree exclusion, conformance — and
  it names no implementor. (implementor policy: the three Discover modules
  delegate with their parameterization; an implementor is whatever
  conforming behaviour module the code path carries, never a hand-written
  registry.)
  """

  @typedoc "The one parameterization a Discover module supplies."
  @type spec :: %{
          required(:namespace) => String.t(),
          required(:behaviour) => module(),
          required(:callbacks) => [{atom(), non_neg_integer()}],
          required(:label) => String.t()
        }

  @doc """
  The discovered, conformed, module-name-sorted implementor set for one
  discovery spec: every loadable module under `namespace` that declares
  `behaviour` and defines the full required `callbacks` set.
  """
  @spec modules(spec()) :: [module()]
  def modules(%{namespace: namespace, behaviour: behaviour, callbacks: callbacks, label: label}) do
    :code.all_available()
    |> Enum.flat_map(&candidates/1)
    |> Enum.uniq()
    |> Enum.filter(&namespace?(&1, namespace))
    |> Enum.reject(&test_source?/1)
    |> Enum.filter(&conforming?(&1, behaviour, callbacks, label))
    |> Enum.sort()
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
