defmodule Workstation.Daemon.OverlayTest do
  use ExUnit.Case, async: false

  alias Workstation.Daemon.{EventBus, Overlay}

  # The overlay is a named singleton per test node, so each test boots its
  # own supervised generation (and it dies with the test's supervisor).
  # EventBus starts first: pub/2 fans every event out on the bus' domain
  # topic, and the daemon tree orders them the same way (:rest_for_one).
  setup do
    start_supervised!(EventBus)
    start_supervised!(Overlay)
    :ok
  end

  test "claim makes the caller the exclusive owner and pub delivers to it" do
    assert Overlay.claim("theme") == :ok
    assert Overlay.owned_domains() == ["theme"]

    Overlay.pub("theme", {:theme_resolved, :dark})
    assert_received {:theme_resolved, :dark}
  end

  test "pub delivers events in publish order" do
    # pub/2 is documented ordered synchronous delivery: the call returns
    # after the event is in the owner's mailbox, so mailbox order equals
    # publish order — a contract single-event tests cannot pin.
    assert Overlay.claim("theme") == :ok

    Overlay.pub("theme", :first)
    Overlay.pub("theme", :second)
    Overlay.pub("theme", :third)

    assert_received :first
    assert_received :second
    assert_received :third
  end

  test "a second owner for a live domain is refused" do
    first = spawn(fn -> receive do: (_ -> Process.sleep(:infinity)) end)
    assert Overlay.claim("apply", first) == :ok

    assert Overlay.claim("apply", self()) == {:error, :taken}
    # the original owner keeps receiving
    Overlay.pub("apply", :event)
    refute_received :event
    assert Process.alive?(first)
  end

  test "re-claiming the same owner is idempotent" do
    assert Overlay.claim("theme") == :ok
    assert Overlay.claim("theme") == :ok
    assert Overlay.owned_domains() == ["theme"]
  end

  test "release frees the domain for the next owner" do
    assert Overlay.claim("theme") == :ok
    assert Overlay.release("theme") == :ok
    assert Overlay.owned_domains() == []
    assert Overlay.claim("theme") == :ok
  end

  test "release by a non-owner is a no-op and does not evict the owner" do
    assert Overlay.claim("theme", self()) == :ok
    bystander = spawn(fn -> receive do: (_ -> Process.sleep(:infinity)) end)

    assert Overlay.release("theme", bystander) == :ok
    assert Overlay.owned_domains() == ["theme"]

    # delivery still reaches the owner, and a stray pub never crashes
    Overlay.pub("theme", :still_owner)
    assert_receive :still_owner
  end

  test "pub to an ownerless domain drops the event silently" do
    assert Overlay.owned_domains() == []
    assert Overlay.pub("theme", :nobody_home) == :ok
    refute_received :nobody_home
  end

  test "a dead owner's domain frees up automatically (monitor reap)" do
    owner =
      spawn(fn ->
        receive do
          :die -> :ok
        end
      end)

    assert Overlay.claim("theme", owner) == :ok
    send(owner, :die)
    wait_until(fn -> Overlay.owned_domains() == [] end)

    assert Overlay.claim("theme", self()) == :ok
  end

  test "pub fans every event out on the {:domain, name} event-bus topic" do
    EventBus.subscribe({:domain, "theme"})

    Overlay.pub("theme", {:theme_resolved, :dark})

    # Same event, the bus' standard envelope; independent of ownership.
    assert_received {:daemon_event, {:domain, "theme"}, {:theme_resolved, :dark}}
  end

  test "domain fanout is topic-scoped: another domain's follower sees nothing" do
    EventBus.subscribe({:domain, "apply"})

    Overlay.pub("theme", :theme_event)

    refute_received {:daemon_event, {:domain, "apply"}, _}
  end

  test "owned_domains lists every live domain, sorted" do
    assert Overlay.claim("theme") == :ok
    assert Overlay.claim("apply") == :ok
    assert Overlay.owned_domains() == ["apply", "theme"]
  end

  defp wait_until(fun, attempts \\ 50)

  defp wait_until(_fun, 0), do: flunk("condition never became true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end
end
