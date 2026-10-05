defmodule Workstation.Daemon.Capabilities.ThemeTest do
  use ExUnit.Case, async: false

  alias Workstation.Core.Theme
  alias Workstation.Daemon.{Capabilities, EventBus, Overlay}

  # EventBus starts before Overlay: pub/2 fans every domain event out on
  # the bus' {:domain, name} topic, and the daemon tree orders them the
  # same way (:rest_for_one).
  setup do
    start_supervised!(EventBus)
    start_supervised!(Overlay)
    :ok
  end

  test "the theme capability owns and registers the theme domain" do
    assert Capabilities.domain_owner("theme") == {:ok, Capabilities.Theme}
    assert Capabilities.Theme.domains() == ["theme"]
  end

  test "handle resolves via Core.Theme and publishes the theme on its domain" do
    assert Overlay.claim("theme", self()) == :ok

    params = %{"appearance" => "dark", "overlays" => [%{"from" => "brand", "set" => %{"accent" => "#ff0000"}}]}

    assert {:ok, theme} = Capabilities.Theme.handle("theme.resolve", params, nil)
    assert theme == Theme.resolve(params) |> elem(1)
    assert theme["colors"]["accent"] == "#ff0000"

    assert_receive {:theme_resolved, published}
    assert published == theme
  end

  test "a refused resolve publishes nothing" do
    assert Overlay.claim("theme", self()) == :ok

    assert {:error, {"invalid_params", _}} =
             Capabilities.Theme.handle("theme.resolve", %{"appearance" => "weird"}, nil)

    refute_received {:theme_resolved, _}
  end

  test "publishing is best-effort: no subscriber, no crash" do
    params = %{"appearance" => "light", "overlays" => []}

    assert {:ok, %{"appearance" => "light"}} =
             Capabilities.Theme.handle("theme.resolve", params, nil)
  end

  describe "domain fanout followers" do
    @params %{"appearance" => "dark", "overlays" => [%{"from" => "brand", "set" => %{"accent" => "#ff0000"}}]}

    test "a follower observes resolved themes without claiming the domain" do
      EventBus.subscribe({:domain, "theme"})

      assert {:ok, theme} = Capabilities.Theme.handle("theme.resolve", @params, nil)

      assert_receive {:daemon_event, {:domain, "theme"}, {:theme_resolved, published}}
      assert published == theme
      # Follower, not owner: the domain stayed free the whole time.
      assert Overlay.owned_domains() == []
    end

    test "owner delivery and follower fanout are independent" do
      assert Overlay.claim("theme", self()) == :ok
      EventBus.subscribe({:domain, "theme"})

      assert {:ok, theme} = Capabilities.Theme.handle("theme.resolve", @params, nil)

      # The owner gets the bare event; the follower gets the envelope copy.
      assert_received {:theme_resolved, ^theme}
      assert_received {:daemon_event, {:domain, "theme"}, {:theme_resolved, ^theme}}
    end

    test "fanout reaches followers even when the domain has no owner" do
      EventBus.subscribe({:domain, "theme"})

      assert {:ok, theme} = Capabilities.Theme.handle("theme.resolve", @params, nil)

      # Ownerless domains drop the DIRECT delivery; the follower fanout is
      # not owner-dependent.
      assert_receive {:daemon_event, {:domain, "theme"}, {:theme_resolved, ^theme}}
    end

    test "followers of other domains see nothing" do
      EventBus.subscribe({:domain, "apply"})

      assert {:ok, _theme} = Capabilities.Theme.handle("theme.resolve", @params, nil)

      refute_received {:daemon_event, {:domain, "apply"}, _}
    end
  end
end
