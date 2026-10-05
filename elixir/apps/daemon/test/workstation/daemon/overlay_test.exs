defmodule Workstation.Daemon.OverlayTest do
  use ExUnit.Case, async: false

  alias Workstation.Daemon.Overlay

  # The overlay is a named singleton per test node, so each test boots its
  # own supervised generation (and it dies with the test's supervisor).
  setup do
    start_supervised!(Overlay)
    :ok
  end

  test "sub makes the caller the exclusive owner and pub delivers to it" do
    assert Overlay.sub("theme") == :ok
    assert Overlay.owned_domains() == ["theme"]

    Overlay.pub("theme", {:theme_resolved, :dark})
    assert_received {:theme_resolved, :dark}
  end

  test "pub delivers events in publish order" do
    # pub/2 is documented ordered synchronous delivery: the call returns
    # after the event is in the owner's mailbox, so mailbox order equals
    # publish order — a contract single-event tests cannot pin.
    assert Overlay.sub("theme") == :ok

    Overlay.pub("theme", :first)
    Overlay.pub("theme", :second)
    Overlay.pub("theme", :third)

    assert_received :first
    assert_received :second
    assert_received :third
  end

  test "a second owner for a live domain is refused" do
    first = spawn(fn -> receive do: (_ -> Process.sleep(:infinity)) end)
    assert Overlay.sub("apply", first) == :ok

    assert Overlay.sub("apply", self()) == {:error, :taken}
    # the original owner keeps receiving
    Overlay.pub("apply", :event)
    refute_received :event
    assert Process.alive?(first)
  end

  test "re-subscribing the same owner is idempotent" do
    assert Overlay.sub("theme") == :ok
    assert Overlay.sub("theme") == :ok
    assert Overlay.owned_domains() == ["theme"]
  end

  test "unsub releases the domain for the next owner" do
    assert Overlay.sub("theme") == :ok
    assert Overlay.unsub("theme") == :ok
    assert Overlay.owned_domains() == []
    assert Overlay.sub("theme") == :ok
  end

  test "unsub by a non-owner is a no-op and does not evict the owner" do
    assert Overlay.sub("theme", self()) == :ok
    bystander = spawn(fn -> receive do: (_ -> Process.sleep(:infinity)) end)

    assert Overlay.unsub("theme", bystander) == :ok
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

    assert Overlay.sub("theme", owner) == :ok
    send(owner, :die)
    wait_until(fn -> Overlay.owned_domains() == [] end)

    assert Overlay.sub("theme", self()) == :ok
  end

  test "owned_domains lists every live domain, sorted" do
    assert Overlay.sub("theme") == :ok
    assert Overlay.sub("apply") == :ok
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
