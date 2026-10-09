defmodule Workstation.Core.Theme.DerivationTest do
  use ExUnit.Case, async: true

  alias Workstation.Core.Theme.Derivation

  # A synthetic consumer's declaration: the platform is consumer-free, so
  # the law is proven on needs no engine module declares.
  @needs %{"roles" => ["accent", "ok", "bg"], "appearances" => ["dark", "light"]}

  describe "declare/1" do
    test "validates and returns a sorted descriptor" do
      assert %{"roles" => ["accent", "bg", "ok"], "appearances" => ["dark", "light"]} =
               Derivation.declare(@needs)
    end

    test "unknown roles and appearances fail closed" do
      assert_raise ArgumentError, ~r/unknown role "chartreuse"/, fn ->
        Derivation.declare(%{"roles" => ["chartreuse"], "appearances" => ["dark"]})
      end

      assert_raise ArgumentError, ~r/unknown appearance "dusk"/, fn ->
        Derivation.declare(%{"roles" => ["accent"], "appearances" => ["dusk"]})
      end
    end

    test "empty and malformed declarations are refused" do
      assert_raise ArgumentError, ~r/at least one role/, fn ->
        Derivation.declare(%{"roles" => [], "appearances" => ["dark"]})
      end

      assert_raise ArgumentError, ~r/must be lists/, fn ->
        Derivation.declare(%{"roles" => "accent", "appearances" => ["dark"]})
      end

      assert_raise ArgumentError, ~r/require \"roles\" and \"appearances\"/, fn ->
        Derivation.declare(%{"roles" => ["accent"]})
      end
    end
  end

  describe "derive/2" do
    test "resolves the declared appearances through the consumer-owned adapter" do
      descriptor = Derivation.declare(@needs)

      artifacts =
        Derivation.derive(descriptor, fn resolved ->
          colors = resolved["colors"]
          "theme:#{resolved["appearance"]}:#{colors["accent"]}/#{colors["bg"]}"
        end)

      assert [{"dark", _}, {"light", _}] = artifacts
      assert {"dark", artifact} = Enum.at(artifacts, 0)
      assert artifact =~ "theme:dark:"
      assert artifact != Enum.at(artifacts, 1) |> elem(1)
    end

    test "the adapter owns rendering and must return a binary" do
      descriptor = Derivation.declare(%{"roles" => ["accent"], "appearances" => ["dark"]})

      assert_raise ArgumentError, ~r/must render a binary/, fn ->
        Derivation.derive(descriptor, fn _resolved -> :not_a_binary end)
      end
    end

    test "derived values come from the token set (one color truth per layer)" do
      descriptor = Derivation.declare(%{"roles" => ["accent"], "appearances" => ["dark"]})

      [{"dark", artifact}] =
        Derivation.derive(descriptor, fn resolved -> resolved["colors"]["accent"] end)

      expected =
        Workstation.Core.Theme.Tokens.palette(:dark)
        |> Enum.find(fn {role, _hex} -> role == :accent end)
        |> elem(1)

      assert artifact == expected
    end
  end
end
