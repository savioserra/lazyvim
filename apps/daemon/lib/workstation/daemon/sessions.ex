defmodule Workstation.Daemon.Sessions do
  # The supervisor is started options-based (no module init callback), so the
  # child_spec is written out instead of `use DynamicSupervisor` — same shape,
  # plus the @max_sessions cap.

  # Declared before the moduledoc so the doc can interpolate the real cap.
  @max_sessions 16

  @moduledoc """
  Session supervisor: a `DynamicSupervisor` holding every accepted client
  session, capped at #{@max_sessions} concurrent sessions.

  Why a cap: each session holds one accepted unix socket and processes one
  frame at a time; an unbounded session count lets a single client turn the
  daemon into a descriptor farm. The cap is enforced by the supervisor's
  `:max_children`, so overflow is a plain `{:error, :max_children}` at
  start_child time and the listener closes the refused socket immediately.

  Sessions are `:temporary` children: a crashed session must never restart
  onto its old socket (the fd would be doubly owned or already closed), so
  clients reconnect instead.
  """

  @doc "Session concurrency ceiling shared by the supervisor and the listener."
  @spec max_sessions() :: pos_integer()
  def max_sessions, do: @max_sessions

  @doc "Currently served session count."
  @spec count_sessions() :: non_neg_integer()
  def count_sessions, do: DynamicSupervisor.count_children(__MODULE__).active

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(
      name: Keyword.get(opts, :name, __MODULE__),
      strategy: :one_for_one,
      max_children: @max_sessions
    )
  end

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}
  end

  @doc "Hand one accepted socket to a fresh session process."
  @spec start_session(pid() | module(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(supervisor \\ __MODULE__, opts), do: DynamicSupervisor.start_child(supervisor, {Workstation.Daemon.Session, opts})
end
