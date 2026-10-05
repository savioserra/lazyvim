defmodule Workstation.Core.ThemeTest do
  use ExUnit.Case, async: true

  alias Workstation.Core.Theme
  alias Workstation.Core.Theme.Tokens

  defp patch(set, from \\ "brand"), do: %{"from" => from, "set" => set}

  # The wire domain is string-keyed (JSON object keys are binaries); the
  # mirror keeps atom keys, so expectations bridge with Atom.to_string.
  defp string_palette(appearance) do
    Map.new(Tokens.palette(appearance), fn {role, hex} -> {Atom.to_string(role), hex} end)
  end

  test "no overlays resolve to the mirrored palette for the appearance" do
    assert {:ok, %{"appearance" => "dark", "colors" => colors}} =
             Theme.resolve(%{"appearance" => "dark", "overlays" => []})

    assert colors == string_palette(:dark)
    assert Map.has_key?(colors, "bg") and Map.has_key?(colors, "muted")
  end

  test "light resolves independently of dark" do
    assert {:ok, %{"colors" => light}} = Theme.resolve(%{"appearance" => "light", "overlays" => []})
    assert {:ok, %{"colors" => dark}} = Theme.resolve(%{"appearance" => "dark", "overlays" => []})
    assert light["bg"] != dark["bg"]
  end

  describe "explicit array order" do
    test "later overlays win per role" do
      overlays = [patch(%{"accent" => "#ff0000"}), patch(%{"accent" => "#00ff00"})]

      assert {:ok, %{"colors" => colors}} =
               Theme.resolve(%{"appearance" => "dark", "overlays" => overlays})

      assert colors["accent"] == "#00ff00"
      # untouched roles survive from the base palette
      assert colors["bg"] == string_palette(:dark)["bg"]
    end

    test "roles inside one overlay are independent of map key order" do
      assert {:ok, %{"colors" => colors}} =
               Theme.resolve(%{
                 "appearance" => "dark",
                 "overlays" => [patch(%{"warn" => "#112233", "err" => "#445566"})]
               })

      assert colors["warn"] == "#112233"
      assert colors["err"] == "#445566"
    end
  end

  describe "rejections (entire envelope)" do
    test "unknown role rejects the envelope" do
      overlays = [patch(%{"accent" => "#ff0000"}), patch(%{"brand" => "#00ff00"})]

      assert {:error, {"invalid_params", message}} =
               Theme.resolve(%{"appearance" => "dark", "overlays" => overlays})

      assert message =~ "unknown role"
    end

    test "palette-only roles are settable (bg, muted)" do
      assert {:ok, %{"colors" => colors}} =
               Theme.resolve(%{
                 "appearance" => "dark",
                 "overlays" => [patch(%{"bg" => "#abcdef", "muted" => "#123456"})]
               })

      assert colors["bg"] == "#abcdef"
      assert colors["muted"] == "#123456"
    end

    test "non-hex values reject the envelope" do
      for bad <- ["red", "#fff", "#12345", "#1234567", "#12345g", "ff0000", ""] do
        assert {:error, {"invalid_params", _}} =
                 Theme.resolve(%{"appearance" => "dark", "overlays" => [patch(%{"accent" => bad})]}),
               "expected #{inspect(bad)} to be rejected"
      end
    end

    test "a bad value in a later overlay rejects even when an earlier one was valid" do
      overlays = [patch(%{"accent" => "#ff0000"}), patch(%{"accent" => "nope"})]
      assert {:error, {"invalid_params", _}} = Theme.resolve(%{"appearance" => "dark", "overlays" => overlays})
    end

    test "unknown appearance rejects the envelope" do
      assert {:error, {"invalid_params", message}} =
               Theme.resolve(%{"appearance" => "system", "overlays" => []})

      assert message =~ "appearance"
    end

    test "a non-list overlays value is refused, never silently ignored" do
      assert {:error, {"invalid_params", message}} =
               Theme.resolve(%{"appearance" => "dark", "overlays" => "nope"})

      assert message =~ "overlays"
    end

    test "garbage params are refused" do
      assert {:error, {"invalid_params", _}} = Theme.resolve(%{})
      assert {:error, {"invalid_params", _}} = Theme.resolve("dark")
    end
  end

  test "empty from source is refused by the schema upstream, unknown from is tolerated here (source is informational)" do
    assert {:ok, %{"colors" => colors}} =
             Theme.resolve(%{"appearance" => "dark", "overlays" => [patch(%{"accent" => "#ff0000"}, "anywhere")]})

    assert colors["accent"] == "#ff0000"
  end
end
