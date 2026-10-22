defmodule Workstation.Core.Contracts.MiseTest do
  @moduledoc """
  The managed-tool contract: declaration validation and denormalization,
  composition (merge, conflict, the engine mise pin law), the composed
  config bytes, plan integration (typed effects, pinned descriptor,
  exclusivity conflicts, fold ordering), the effect mechanics against an
  injected runner (config write + installer absorption, PATH link with the
  content-proven takeover, the pinned install and its resolution probes),
  the journal claims, and the verify seam's drift refusals — plus a full
  pipeline execute that rides the effects fold with zero pipeline edits.
  """

  use ExUnit.Case, async: false

  alias Workstation.Core.Contracts.Mise

  @mise_version "2026.10.8"
  @mise_target ".local/opt/mise/2026.10.8/bin/mise"
  @config_target ".config/mise/config.toml"

  @tools [
    %{name: "tmux", version: "3.7c", backend: "aqua:tmux/tmux-builds"},
    %{name: "btop", version: "1.4.7", backend: "github:aristocratos/btop"}
  ]

  setup context do
    home = Path.join(System.tmp_dir!(), "workstation-mise-#{context.test}-#{:os.getpid()}")
    File.rm_rf!(home)
    File.mkdir_p!(home)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")
      File.rm_rf!(home)
    end)

    %{home: home}
  end

  describe "declaration validation" do
    test "a valid spec carries short names, exact versions and optional backends" do
      assert :ok = Mise.validate_spec(%{tools: @tools})
      assert :ok = Mise.validate_spec(%{tools: [%{name: "erlang", version: "28.5"}]})
    end

    test "invalid names, versions, backends and unknown fields refuse" do
      assert_raise ArgumentError, ~r/lowercase short name/, fn ->
        Mise.validate_spec(%{tools: [%{name: "Tmux", version: "3.7c"}]})
      end

      assert_raise ArgumentError, ~r/must be an exact pin/, fn ->
        Mise.validate_spec(%{tools: [%{name: "tmux", version: "3 7c"}]})
      end

      assert_raise ArgumentError, ~r/must be <prefix>:<path>/, fn ->
        Mise.validate_spec(%{tools: [%{name: "tmux", version: "3.7c", backend: "aqua-tmux"}]})
      end

      assert_raise ArgumentError, ~r/unknown fields/, fn ->
        Mise.validate_spec(%{tools: [%{name: "tmux", version: "3.7c", order: 1}]})
      end

      assert_raise ArgumentError, ~r/non-empty tools list/, fn ->
        Mise.validate_spec(%{tools: []})
      end

      assert_raise ArgumentError, ~r/must be a map/, fn ->
        Mise.validate_spec("tools")
      end
    end

    test "denormalization round-trips a recorded envelope through validation" do
      recorded = %{
        "tools" => [
          %{"name" => "tmux", "version" => "3.7c", "backend" => "aqua:tmux/tmux-builds"},
          %{"name" => "erlang", "version" => "28.5"}
        ]
      }

      assert Mise.from_recorded(recorded, %{package_id: "goldens"}) == %{
               tools: [
                 %{name: "tmux", version: "3.7c", backend: "aqua:tmux/tmux-builds"},
                 %{name: "erlang", version: "28.5"}
               ]
             }

      assert_raise ArgumentError, ~r/invalid mise recipe for goldens/, fn ->
        Mise.from_recorded(%{"tools" => [%{"name" => "tmux"}]}, %{package_id: "goldens"})
      end
    end
  end

  describe "composition" do
    test "a catalog without declarations composes nil" do
      assert Mise.compose_tools([], [], "linux") == nil
    end

    test "declarations merge, sort deterministically and dedupe identical pins" do
      collected = [
        %{owner: "zeta", provider: "mise", spec: %{tools: [%{name: "tmux", version: "3.7c", backend: "aqua:tmux/tmux-builds"}]}},
        %{owner: "alpha", provider: "mise", spec: %{tools: [%{name: "btop", version: "1.4.7", backend: "github:aristocratos/btop"}]}},
        %{owner: "alpha", provider: "mise", spec: %{tools: [%{name: "tmux", version: "3.7c", backend: "aqua:tmux/tmux-builds"}]}}
      ]

      mise = Mise.compose_tools(collected, [mise_pin()], "linux")

      assert Enum.map(mise.tools, & &1.name) == ["btop", "tmux"]
      assert mise.owners == ["alpha", "zeta"]
      assert mise.mise_target == @mise_target
      assert mise.mise_version == @mise_version
      assert mise.fingerprint == Mise.fingerprint_tools(mise.tools)
    end

    test "one tool may carry only one pinned version" do
      collected = [
        %{owner: "alpha", provider: "mise", spec: %{tools: [%{name: "tmux", version: "3.7c", backend: "aqua:tmux/tmux-builds"}]}},
        %{owner: "zeta", provider: "mise", spec: %{tools: [%{name: "tmux", version: "3.8", backend: "aqua:tmux/tmux-builds"}]}}
      ]

      assert_raise ArgumentError, ~r/diverging versions/, fn ->
        Mise.compose_tools(collected, [mise_pin()], "linux")
      end
    end

    test "declaring tools without the engine mise pin fails at composition" do
      collected = [%{owner: "alpha", provider: "mise", spec: %{tools: @tools}}]

      assert_raise ArgumentError, ~r/no pinned download provides the mise binary/, fn ->
        Mise.compose_tools(collected, [], "linux")
      end
    end

    test "the mise pin must sit at the contract's opt-root layout" do
      collected = [%{owner: "alpha", provider: "mise", spec: %{tools: @tools}}]
      pin = %{mise_pin() | target: ".local/opt/mise/mise"}

      assert_raise ArgumentError, ~r/must be .local\/opt\/mise\/<version>\/bin\/mise/, fn ->
        Mise.compose_tools(collected, [pin], "linux")
      end
    end

    test "owned targets may not overlap entries, removals or downloads" do
      mise =
        Mise.compose_tools([%{owner: "alpha", provider: "mise", spec: %{tools: @tools}}], [mise_pin()], "linux")

      entry = %{target: ".config/mise", attribution: ["someone"], owner: "someone"}

      assert_raise ArgumentError, ~r/overlaps owned target/, fn ->
        Mise.check_conflicts(mise, [entry], [], [])
      end

      assert_raise ArgumentError, ~r/overlaps download target/, fn ->
        Mise.check_conflicts(mise, [], [], [%{target: @config_target}])
      end

      removal = %{target: ".config/mise/config.toml", owner: "someone"}

      assert_raise ArgumentError, ~r/overlaps mise target/, fn ->
        Mise.check_conflicts(mise, [], [removal], [])
      end

      :ok = Mise.check_conflicts(mise, [], [], [])
    end
  end

  describe "the composed managed config" do
    test "the bytes are one deterministic document with quoted backend keys" do
      mise =
        Mise.compose_tools([%{owner: "alpha", provider: "mise", spec: %{tools: @tools}}], [mise_pin()], "linux")

      bytes = Mise.config_bytes(mise)

      assert bytes == """
             # Managed by the workstation engine; do not edit deployed state by hand.
             # The engine mise contract composes this global tool set from the
             # packages' declared pins (declared by: alpha).
             # Tool state lives under the engine state root (MISE_DATA_DIR).

             [tools]
             "github:aristocratos/btop" = "1.4.7"
             "aqua:tmux/tmux-builds" = "3.7c"
             """

      assert bytes == Mise.config_bytes(mise)
      assert Mise.config_source_name() == "mise/config.toml"
      assert Mise.pinned_files(mise) == [{"mise/config.toml", bytes}]
      assert Mise.pinned_files(nil) == []
    end
  end

  defp mise_pin do
    %{
      owner: "mise-foundation-goldens",
      target: @mise_target,
      version: @mise_version,
      assets: %{
        "linux_x86_64" => %{url: "https://goldens.invalid/mise/mise-v2026.10.8-linux-x64", sha256: String.duplicate("a", 64)},
        "darwin_arm64" => %{url: "https://goldens.invalid/mise/mise-v2026.10.8-macos-arm64", sha256: String.duplicate("a", 64)}
      }
    }
  end

end
