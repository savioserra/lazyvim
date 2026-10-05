defmodule Workstation.Core.Graph do
  @moduledoc """
  Capability graph resolution: resolves package specs into a deterministic,
  host-aware execution order.

  Order is deterministic and host-aware: specs unsupported on the host are
  excluded, `requires` dependencies must exist for every spec and must be
  supported for every enabled spec, cycles are rejected with the cycle path
  in the error, and the topological result is a post-order DFS over the
  id-sorted specs — dependency-equal packages resolve by id sort, never by
  declaration order. Unknown providers and duplicate ids are rejected here,
  never silently ignored downstream.

  Two edge kinds connect packages:

  * `requires` — necessity plus ordering: the dependency must exist, be
    enabled on the host, and is sequenced first (missing or unsupported
    dependencies are rejected);
  * `after` — ordering only (systemd `After=` semantics): the edge
    sequences the package after the target ONLY when the target is present
    and enabled on the host. A missing or disabled target neither fails
    the composition nor pulls the package in.
  """

  defstruct [:ordered, :enabled]

  @type specification :: %{
          required(:id) => String.t(),
          optional(:requires) => [String.t()] | nil,
          optional(:after) => [String.t()] | nil,
          optional(:supported_hosts) => %{optional(String.t()) => boolean()} | nil,
          optional(:foundation) => String.t(),
          optional(:contributes) => [term()] | nil
        }

  @doc """
  Resolve `specifications` (the validated catalog packages) for `host`.
  Returns `%Graph{}` with `ordered` (topological, id-stable) and `enabled`
  (the set of included ids). The input list order never leaks into the
  result: iteration starts from the id-sorted specs.
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
      id = Map.fetch!(spec, :id)

      Enum.each(Map.get(spec, :requires) || [], fn dependency ->
        Map.has_key?(capabilities, dependency) ||
          raise ArgumentError, "#{id} requires unknown capability #{dependency}"

        is_binary(dependency) || raise ArgumentError, "#{id} has a non-string requires edge"
      end)

      Enum.each(Map.get(spec, :after) || [], fn dependency ->
        is_binary(dependency) or
          raise ArgumentError, "#{id} has a non-string after edge: #{inspect(dependency)}"
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

    # The tie-break is the id sort: dependency-equal specs resolve by id,
    # so no declaration or registration order can leak into the plan.
    {visited_results, _visited} =
      specifications
      |> Enum.sort_by(& &1.id)
      |> Enum.map_reduce(%{}, fn spec, visited ->
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
        cycle = [id | stack] |> Enum.reverse() |> Enum.join(" -> ")
        raise ArgumentError, "capability dependency cycle at #{id}: #{cycle}"

      true ->
        spec = Map.fetch!(capabilities, id)
        stack = [id | stack]

        Enum.each(Map.get(spec, :requires) || [], fn dependency ->
          enabled[dependency] == true ||
            raise ArgumentError, "#{id} requires unsupported capability #{dependency}"
        end)

        # Post-order DFS: dependencies first. requires edges are necessity
        # (existence + host support already validated); after edges are
        # sequencing-only — a target that is absent or disabled is skipped
        # without failing or pulling anything in. `visit` returns early for
        # ids outside `enabled`, so a missing after target is a no-op.
        children = (Map.get(spec, :requires) || []) ++ (Map.get(spec, :after) || [])

        {nested, visited} =
          Enum.map_reduce(children, visited, fn dependency, acc ->
            visit(dependency, capabilities, enabled, acc, stack)
          end)

        # Each visit emits a (possibly nested) list; the visited check keeps
        # every id emitted exactly once, so flattening cannot duplicate
        # contributors.
        {List.flatten(nested ++ [spec]), Map.put(visited, id, true)}
    end
  end
end
