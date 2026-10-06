defmodule Workstation.Daemon.Capabilities.Assembly do
  @moduledoc """
  Compile-time assembly helpers for the capability registry.

  Pure index builders over a list of `Workstation.Daemon.Capability` modules.
  Duplicate op names or duplicate domain names raise `ArgumentError` here —
  and because `Workstation.Daemon.Capabilities` runs this at compile time,
  a duplicate anywhere in `@registry` fails the build instead of shipping an
  ambiguous daemon surface. Public so tests exercise the real raise paths.
  """

  @spec op_index!([module()]) :: %{String.t() => module()}
  def op_index!(modules) do
    Enum.reduce(modules, %{}, fn module, acc ->
      Enum.reduce(module.ops(), acc, fn op, inner ->
        if Map.has_key?(inner, op) do
          raise ArgumentError,
                "duplicate daemon op #{inspect(op)} served by both " <>
                  "#{inspect(Map.fetch!(inner, op))} and #{inspect(module)}"
        end

        Map.put(inner, op, module)
      end)
    end)
  end

  @spec domain_index!([module()]) :: %{String.t() => module()}
  def domain_index!(modules) do
    Enum.reduce(modules, %{}, fn module, acc ->
      Enum.reduce(module.domains(), acc, fn domain, inner ->
        if Map.has_key?(inner, domain) do
          raise ArgumentError,
                "duplicate daemon pubsub domain #{inspect(domain)} owned by both " <>
                  "#{inspect(Map.fetch!(inner, domain))} and #{inspect(module)}"
        end

        Map.put(inner, domain, module)
      end)
    end)
  end
end

defmodule Workstation.Daemon.Capabilities do
  @moduledoc """
  Compile-time capability registry: the single place where the daemon's
  served op set, pubsub domains, op dispatch and capability children are
  assembled.

  Every module in `@registry` implements the `Workstation.Daemon.Capability`
  behaviour. Assembly happens at compile time from that list
  (`Workstation.Daemon.Capabilities.Assembly`), so the served surface is
  fully determined by `@registry`; ops and domains not backed by a
  registered module cannot exist. Duplicate op names or duplicate domain
  names across capabilities raise at compile time.

  `Workstation.Daemon.Protocol` advertises `ops/0` and `domains/0` in the
  hello handshake, `Workstation.Daemon.Protocol.decode_params/2` validates
  through `schema/1`, and `Workstation.Daemon.Session` dispatches through
  `dispatch/3` — one generic clause, no per-op session code.
  """

  alias Workstation.Daemon.Capabilities.Assembly
  alias Workstation.Daemon.Capability

  @registry [
    Workstation.Daemon.Capabilities.Overlay,
    Workstation.Daemon.Capabilities.Theme,
    Workstation.Daemon.Capabilities.Apply,
    Workstation.Daemon.Capabilities.Lifecycle,
    Workstation.Daemon.Capabilities.Read,
    Workstation.Daemon.Capabilities.Control,
    Workstation.Daemon.Capabilities.UpdateCheck
  ]

  @typedoc "Session context passed through to capability handlers."
  @type ctx :: Capability.ctx()

  @typedoc "Wire result every op handler returns."
  @type handle_result :: Capability.handle_result()

  @op_index Assembly.op_index!(@registry)
  @domain_index Assembly.domain_index!(@registry)
  @ops @op_index |> Map.keys() |> Enum.sort()
  @domains @domain_index |> Map.keys() |> Enum.sort()
  @children Enum.flat_map(@registry, & &1.children())

  # --- registry contract -----------------------------------------------------

  @doc "Capability modules in registration order."
  @spec registry() :: [module()]
  def registry, do: @registry

  @doc "All served wire op names, sorted."
  @spec ops() :: [String.t()]
  def ops, do: @ops

  @doc "All registered pubsub domain names, sorted."
  @spec domains() :: [String.t()]
  def domains, do: @domains

  @doc "Capability module serving `op`, if any."
  @spec owner(String.t()) :: {:ok, module()} | :error
  def owner(op), do: Map.fetch(@op_index, op)

  @doc "Capability module owning `domain`, if any."
  @spec domain_owner(String.t()) :: {:ok, module()} | :error
  def domain_owner(domain), do: Map.fetch(@domain_index, domain)

  @doc "Capability children, already flattened in registration order."
  @spec children() :: [Supervisor.child_spec() | module()]
  def children, do: @children

  @doc "Strict params schema for a served op, else the unknown-op refusal."
  @spec schema(String.t()) :: {:ok, Zoi.Schema.t()} | {:error, {String.t(), String.t()}}
  def schema(op)

  for {op, module} <- @op_index do
    def schema(unquote(op)), do: {:ok, unquote(module).schema(unquote(op))}
  end

  def schema(_op), do: {:error, Workstation.Daemon.Protocol.unknown_op()}

  @doc """
  Dispatch one schema-validated op to its owning capability.

  Unknown ops refuse with the protocol's `unknown_op` error; handler errors
  pass through unchanged (the session maps them onto the wire).
  """
  @spec dispatch(String.t(), map(), Capability.ctx()) :: handle_result()
  def dispatch(op, params, ctx)

  for {op, module} <- @op_index do
    def dispatch(unquote(op), params, ctx),
      do: unquote(module).handle(unquote(op), params, ctx)
  end

  def dispatch(_op, _params, _ctx), do: {:error, Workstation.Daemon.Protocol.unknown_op()}
end
