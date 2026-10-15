defmodule Workstation.Daemon.EventBusTest do
  @moduledoc """
  The EventBus pub/sub contract: the delivery envelope every daemon consumer
  codes against, topic scoping, duplicate fanout (every subscriber gets its
  own copy — the registry replaces any central broadcaster), and the
  from-now-on subscription semantics documented on `subscribe/1`.
  """

  use ExUnit.Case, async: false

  alias Workstation.Daemon.EventBus

  setup do
    start_supervised!(EventBus)
    :ok
  end

  test "a subscriber receives published events wrapped as {:daemon_event, topic, event}" do
    :ok = EventBus.subscribe(:op)

    :ok = EventBus.publish(:op, {:op_served, "theme.resolve"})

    assert_receive {:daemon_event, :op, {:op_served, "theme.resolve"}}
  end

  test "delivery is topic-scoped: other topics' events never arrive" do
    :ok = EventBus.subscribe(:session)

    :ok = EventBus.publish(:op, {:op_served, "hello"})
    refute_received {:daemon_event, :op, _}

    :ok = EventBus.publish(:session, {:session_opened, 0})
    assert_receive {:daemon_event, :session, {:session_opened, 0}}
  end

  test "every current subscriber receives its own copy of a published event" do
    parent = self()

    other =
      spawn(fn ->
        :ok = EventBus.subscribe(:op)
        send(parent, :subscribed)

        receive do
          {:daemon_event, :op, event} -> send(parent, {:copy, event})
        after
          2_000 -> send(parent, {:copy, :timeout})
        end
      end)

    assert_receive :subscribed
    :ok = EventBus.subscribe(:op)

    :ok = EventBus.publish(:op, {:op_served, "hello"})

    assert_receive {:daemon_event, :op, {:op_served, "hello"}}
    assert_receive {:copy, {:op_served, "hello"}}
    _ = other
  end

  test "events published before subscription are not delivered (from now on)" do
    :ok = EventBus.publish(:op, {:op_served, "early"})
    :ok = EventBus.subscribe(:op)

    # Dispatch is synchronous: a pre-subscription publish had no subscriber
    # and can never arrive late; the post-subscription publish proves the
    # subscription is live.
    refute_received {:daemon_event, :op, {:op_served, "early"}}

    :ok = EventBus.publish(:op, {:op_served, "late"})
    assert_receive {:daemon_event, :op, {:op_served, "late"}}
  end

  test "a NOT-RUNNING bus: publish and unsubscribe are no-ops, not crashes" do
    # The teardown race the rest_for_one order creates: the bus stops
    # BEFORE the sessions, so a session draining its last frames — the stop
    # ack's finish_op unsubscribe is exactly that last mile — can reach the
    # bus after it is gone. Under load this surfaced as a session GenServer
    # crash (ArgumentError: unknown registry) that ate the operator's
    # `daemon stop` ack: the verb then reported {:shutdown, 4} on a stop
    # that was actually granted. Nobody is owed the event and nobody needs
    # the unregistration — the teardown must never surface as a crash.
    :ok = GenServer.stop(Workstation.Daemon.EventBus)
    wait_bus_down()

    assert :ok = EventBus.publish(:op, {:op_served, "nobody is owed this"})
    assert :ok = EventBus.unsubscribe(:op)
  end

  defp wait_bus_down do
    if Process.whereis(Workstation.Daemon.EventBus) == nil do
      :ok
    else
      Process.sleep(10)
      wait_bus_down()
    end
  end
end
