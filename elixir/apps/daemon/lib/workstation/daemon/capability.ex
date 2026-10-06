defmodule Workstation.Daemon.Capability do
  @moduledoc """
  Behaviour every served daemon capability implements.

  A capability is a domain served over the daemon wire protocol. It owns:

    * `ops/0` — the wire op names it serves (globally unique)
    * `schema/1` — the strict Zoi params schema for one of its ops
    * `handle/2` — execute one op and return the wire result
    * `domains/0` — pubsub domain names it registers (globally unique)
    * `children/0` — optional supervised processes it needs

  `use Workstation.Daemon.Capability` provides empty defaults so a capability
  only overrides what it serves. The `Workstation.Daemon.Capabilities`
  namespace assembles the registry from `@registry` at compile time and
  raises on duplicate op or domain names.
  """

  @typedoc "Wire result every op handler returns."
  @type handle_result ::
          {:ok, map()}
          | {:error, {String.t(), String.t()}}
          | :protocol_mismatch

  @typedoc """
  Session context handed to op handlers. Off-wire callers pass nil (or a
  pid, the pre-streaming spelling, still accepted). The streaming session
  passes a map: `session` is the calling session pid and `op_ref` the op's
  stream token — the handle the op uses to publish progress events
  (`Workstation.Daemon.Events`).
  """
  @type ctx :: %{optional(:session) => pid(), optional(:op_ref) => String.t()} | pid() | nil

  @doc "Wire op names served by this capability."
  @callback ops() :: [String.t()]

  @doc "Strict Zoi params schema for one of this capability's ops."
  @callback schema(String.t()) :: Zoi.Schema.t() | nil

  @doc """
  Handle one op with already-schema-validated params. `ctx` identifies the
  calling session (pid, nil off-wire, or the streaming session map with the
  op's `op_ref` token). `handle/3` never raises for expected protocol
  failures; unexpected exceptions are the session's internal-error boundary.
  """
  @callback handle(String.t(), map(), ctx()) :: handle_result()

  @doc "Pubsub domain names this capability registers."
  @callback domains() :: [String.t()]

  @doc "Supervised children this capability contributes (rare; infra stays central)."
  @callback children() :: [Supervisor.child_spec() | module()]

  @doc """
  The op's stream token for `ctx`: the session's `op_ref` on the wire, or a
  fresh one off-wire (events published to no subscriber are no-ops, so an
  in-process caller needs no coordination to run the same handles).
  """
  @spec op_ref(ctx()) :: String.t()
  def op_ref(%{op_ref: ref}) when is_binary(ref), do: ref
  def op_ref(_ctx), do: Workstation.Daemon.Events.new_ref()

  @doc """
  Caller-supplied op options for `ctx` (fixture seams for module-level
  tests — home, installer, bootstrap run). The wire session never sets
  them: on the wire ops serve the daemon's own pinned environment, so a
  client cannot smuggle options through params (they never reach ctx).
  """
  @spec opts(ctx()) :: keyword()
  def opts(%{opts: opts}) when is_list(opts), do: opts
  def opts(_ctx), do: []

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour Workstation.Daemon.Capability

      @impl true
      def ops, do: []

      @impl true
      def schema(_op), do: nil

      @impl true
      def handle(_op, _params, _ctx), do: {:error, Workstation.Daemon.Protocol.unknown_op()}

      @impl true
      def domains, do: []

      @impl true
      def children, do: []

      defoverridable ops: 0, schema: 1, handle: 3, domains: 0, children: 0
    end
  end
end
