defmodule Workstation.Core.Platform.ProfileTest do
  use ExUnit.Case, async: true

  alias Workstation.Core.Platform.Profile

  # A synthetic editor's vocabulary: the platform is consumer-free, so the
  # generic law is proven on a shape no engine module declares. This is the
  # seam a helix/zed-style capability would ride — its own fields, its own
  # serializer, the same envelope and ordering law.
  @shape %{
    string_fields: [:id, :section],
    list_fields: [:modes],
    case_fields: %{key_cases: [:key, :binding]}
  }

  describe "declared_entry/2" do
    test "fills every declared field, normalizing case records" do
      entry =
        Profile.declared_entry(
          %{id: "core", section: "editor", modes: ["insert", "normal"],
           key_cases: [%{key: "g g", binding: "top", project_files: %{"mix.exs" => "elixir"}}]},
          @shape
        )

      assert entry == %{
               id: "core",
               section: "editor",
               modes: ["insert", "normal"],
               key_cases: [%{key: "g g", binding: "top", project_files: %{"mix.exs" => "elixir"}}]
             }
    end

    test "an omitted field is nil, an omitted case list is nil, cases carry exact base fields" do
      entry = Profile.declared_entry(%{id: "lean", key_cases: [%{key: "w", binding: "next"}]}, @shape)

      assert entry.section == nil
      assert entry.modes == nil
      assert entry.key_cases == [%{key: "w", binding: "next"}]
    end
  end

  describe "recorded_spec/3" do
    test "denormalizes the string-keyed envelope to the declared atom shape" do
      declared =
        Profile.declared_entry(
          %{id: "core", modes: ["normal"], key_cases: [%{key: "j", binding: "down"}]},
          @shape
        )

      recorded =
        Profile.recorded_spec(
          %{
            "order" => 2,
            "entry" => %{
              "id" => "core",
              "modes" => ["normal"],
              "key_cases" => [%{"key" => "j", "binding" => "down"}]
            }
          },
          @shape,
          "test-profile"
        )

      assert recorded == %{order: 2, entry: declared}
    end

    test "order must be a positive integer and the entry a table (label threaded)" do
      assert_raise ArgumentError, "test-profile order must be a positive integer", fn ->
        Profile.recorded_spec(%{"order" => 0, "entry" => %{"id" => "x"}}, @shape, "test-profile")
      end

      assert_raise ArgumentError, "test-profile entry must be a table", fn ->
        Profile.recorded_spec(%{"order" => 1, "entry" => "nope"}, @shape, "test-profile")
      end
    end

    test "list values fail closed, unknown entry fields are tolerated" do
      assert_raise ArgumentError, "test-profile list values must be non-empty strings", fn ->
        Profile.recorded_spec(
          %{"order" => 1, "entry" => %{"id" => "x", "modes" => [""]}},
          @shape,
          "test-profile"
        )
      end

      recorded =
        Profile.recorded_spec(
          %{"order" => 1, "entry" => %{"id" => "x", "unknown_thing" => %{"deep" => true}}},
          @shape,
          "test-profile"
        )

      assert recorded.entry.id == "x"
    end
  end

  describe "composition law" do
    test "order_intents sorts by explicit order with collection order as tie-break" do
      intents = [
        %{owner: "b", spec: %{order: 20, entry: %{id: "second-b"}}},
        %{owner: "a", spec: %{order: 10, entry: %{id: "first-a"}}},
        %{owner: "c", spec: %{order: 10, entry: %{id: "first-c"}}}
      ]

      ids = Enum.map(Profile.order_intents(intents), & &1.id)
      assert ids == ["first-a", "first-c", "second-b"]
    end

    test "validate_profile rejects duplicates, non-lists and invalid entries under the shape" do
      assert_raise ArgumentError, "duplicate editor profile contribution: dup", fn ->
        Profile.validate_profile([%{id: "dup"}, %{id: "dup"}], @shape, "editor profile")
      end

      assert_raise ArgumentError, "editor profile must be a list", fn ->
        Profile.validate_profile(%{id: "not-a-list"}, @shape, "editor profile")
      end

      assert_raise ArgumentError, "editor profile[1].modes[2] must be a non-empty string", fn ->
        Profile.validate_profile([%{id: "x", modes: ["ok", ""]}], @shape, "editor profile")
      end

      assert_raise ArgumentError, "editor profile[1].key_cases[1].binding must be a non-empty string", fn ->
        Profile.validate_profile([%{id: "x", key_cases: [%{key: "k", binding: nil}]}], @shape, "editor profile")
      end
    end

    test "validate_profile returns the profile unchanged when valid" do
      profile = [%{id: "a", section: "s", modes: nil, key_cases: nil}]
      assert Profile.validate_profile(profile, @shape, "editor profile") == profile
    end
  end
end
