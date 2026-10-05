defmodule Workstation.Core.Graph do
  @moduledoc """
  Capability graph resolution: resolves package specs into a deterministic,
  host-aware execution order.

  Order is deterministic and host-aware: specs unsupported on the host are
  excluded, dependencies must exist for every spec and must be supported for
  every enabled spec, cycles are rejected, and the topological result is a
  post-order DFS over the declaration order so equal-priority contributors
  keep catalog order. Unknown providers and duplicate ids are rejected here,
  never silently ignored downstream.
  """

  defstruct [:ordered, :enabled]

  @type specification :: %{
          required(:id) => String.t(),
          optional(:requires) => [String.t()] | nil,
          optional(:supported_hosts) => %{optional(String.t()) => boolean()} | nil,
          optional(:foundation) => String.t(),
          optional(:contributes) => [term()] | nil
        }

  @doc """
  Resolve `specifications` (the validated catalog packages) for `host`.
  Returns `%Graph{}` with `ordered` (topological, declaration-stable) and
  `enabled` (the set of included ids).
  """
  @spec order(%{required(:host) => String.t(), required(:specifications) => [specification()]}) ::
          %__MODULE__{}
  def order(%{host: host, specifications: specifications}) do
    is_binary(host) and host != "" || raise ArgumentError, "graph resolution requires a host name"

    capabilities =
      Enum.reduce(specifications, %{}, fn spec, acc ->
        id = Map.fetch!(spec, :id)
        Map.has_key?(acc, id) && raise ArgumentError, "duplicate capability: #{id}"
        Map.put(acc, id, spec)
      end)

    Enum.each(specifications, fn spec ->
      Enum.each(Map.get(spec, :requires) || [], fn dependency ->
        Map.has_key?(capabilities, dependency) ||
          raise ArgumentError, "#{Map.fetch!(spec, :id)} requires unknown capability #{dependency}"
      end)
    end)

    enabled =
      Map.new(specifications, fn spec ->
        id = Map.fetch!(spec, :id)

        supported? =
          case Map.get(spec, :supported_hosts) do
            nil -> true
            hosts -> Map.get(hosts, host) == true
          end

        {id, supported?}
      end)

    {visited_results, _visited} =
      Enum.map_reduce(specifications, %{}, fn spec, visited ->
        visit(spec.id, capabilities, enabled, visited, [])
      end)

    # One flat topological list: each visit already emits its dependencies
    # before its own spec, so a final flatten preserves post-order stability.
    ordered = List.flatten(visited_results)

    %__MODULE__{ordered: ordered, enabled: enabled}
  end

  defp visit(id, capabilities, enabled, visited, stack) do
    cond do
      enabled[id] != true ->
        {[], visited}

      Map.has_key?(visited, id) ->
        {[], visited}

      id in stack ->
        raise ArgumentError, "capability dependency cycle at #{id}"

      true ->
        spec = Map.fetch!(capabilities, id)
        stack = [id | stack]

        Enum.each(Map.get(spec, :requires) || [], fn dependency ->
          enabled[dependency] == true ||
            raise ArgumentError, "#{id} requires unsupported capability #{dependency}"
        end)

        {nested, visited} =
          Enum.map_reduce(Map.get(spec, :requires) || [], visited, fn dependency, acc ->
            visit(dependency, capabilities, enabled, acc, stack)
          end)

        # Post-order DFS: dependencies first. Each visit emits a (possibly
        # nested) list; the visited check keeps every id emitted exactly
        # once, so flattening cannot duplicate contributors.
        {List.flatten(nested ++ [spec]), Map.put(visited, id, true)}
    end
  end
end
