defmodule Workstation.Daemon.Capabilities.ThemeTest do
  use ExUnit.Case, async: false

  alias Workstation.Core.Theme
  alias Workstation.Daemon.{Capabilities, Overlay}

  setup do
    start_supervised!(Overlay)
    :ok
  end

  test "the theme capability owns and registers the theme domain" do
    assert Capabilities.domain_owner("theme") == {:ok, Capabilities.Theme}
    assert Capabilities.Theme.domains() == ["theme"]
  end

  test "handle resolves via Core.Theme and publishes the theme on its domain" do
    assert Overlay.sub("theme", self()) == :ok

    params = %{"appearance" => "dark", "overlays" => [%{"from" => "brand", "set" => %{"accent" => "#ff0000"}}]}

    assert {:ok, theme} = Capabilities.Theme.handle("theme.resolve", params, nil)
    assert theme == Theme.resolve(params) |> elem(1)
    assert theme["colors"]["accent"] == "#ff0000"

    assert_receive {:theme_resolved, published}
    assert published == theme
  end

  test "a refused resolve publishes nothing" do
    assert Overlay.sub("theme", self()) == :ok

    assert {:error, {"invalid_params", _}} =
             Capabilities.Theme.handle("theme.resolve", %{"appearance" => "weird"}, nil)

    refute_received {:theme_resolved, _}
  end

  test "publishing is best-effort: no subscriber, no crash" do
    params = %{"appearance" => "light", "overlays" => []}

    assert {:ok, %{"appearance" => "light"}} =
             Capabilities.Theme.handle("theme.resolve", params, nil)
  end
end
