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

  alias Workstation.Core.{Catalog, Digest, EngineState, Graph, Journal, Source}
  alias Workstation.Core.Contracts.Mise
  alias Workstation.Pipeline

  @mise_version "2026.10.8"
  @mise_target ".local/opt/mise/2026.10.8/bin/mise"
  @config_target ".config/mise/config.toml"
  @link_target ".local/bin/mise"
  @data_target ".local/state/workstation/mise"

  @tools [
    %{name: "tmux", version: "3.7c", backend: "aqua:tmux/tmux-builds"},
    %{name: "btop", version: "1.4.7", backend: "github:aristocratos/btop"}
  ]

  # The stand-in pinned bytes; the injected fetch serves them, the download
  # contract verifies them against this sha, and the link absorption proof
  # recognizes the installer copy by the same digest.
  @fake_mise "#!/bin/sh\n# goldens fake mise\n"
  @mise_sha Digest.sha256(@fake_mise)

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
      assert Mise.compose_tools([], []) == nil
    end

    test "declarations merge, sort deterministically and dedupe identical pins" do
      collected = [
        %{owner: "zeta", provider: "mise", spec: %{tools: [%{name: "tmux", version: "3.7c", backend: "aqua:tmux/tmux-builds"}]}},
        %{owner: "alpha", provider: "mise", spec: %{tools: [%{name: "btop", version: "1.4.7", backend: "github:aristocratos/btop"}]}},
        %{owner: "alpha", provider: "mise", spec: %{tools: [%{name: "tmux", version: "3.7c", backend: "aqua:tmux/tmux-builds"}]}}
      ]

      mise = Mise.compose_tools(collected, [mise_pin()])

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
        Mise.compose_tools(collected, [mise_pin()])
      end
    end

    test "declaring tools without the engine mise pin fails at composition" do
      collected = [%{owner: "alpha", provider: "mise", spec: %{tools: @tools}}]

      assert_raise ArgumentError, ~r/no pinned download provides the mise binary/, fn ->
        Mise.compose_tools(collected, [])
      end
    end

    test "the mise pin must sit at the contract's opt-root layout" do
      collected = [%{owner: "alpha", provider: "mise", spec: %{tools: @tools}}]
      pin = %{mise_pin() | target: ".local/opt/mise/mise"}

      assert_raise ArgumentError, ~r/must be .local\/opt\/mise\/<version>\/bin\/mise/, fn ->
        Mise.compose_tools(collected, [pin])
      end
    end

    test "owned targets may not overlap entries, removals or downloads" do
      mise = Mise.compose_tools([%{owner: "alpha", provider: "mise", spec: %{tools: @tools}}], [mise_pin()])
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
      mise = Mise.compose_tools([%{owner: "alpha", provider: "mise", spec: %{tools: @tools}}], [mise_pin()])

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

  describe "plan integration" do
    test "declarations compose into the plan's tool set, effects and pinned descriptor" do
      plan = build_plan()

      assert %{tools: tools, owners: ["mise-tools-goldens"]} = plan.mise
      assert Enum.map(tools, & &1.name) == ["btop", "tmux"]

      # The composed config descriptor rides the generation: a pin change
      # moves the generation id, the same law the download descriptors follow.
      assert Enum.find(plan.manifest, &(&1["name"] == "mise/config.toml"))

      effects = Pipeline.effects(plan)
      mise_effects = Enum.filter(effects, &(&1.contract == "mise"))

      assert [%{kind: :configure, target: config_target}, %{kind: :link, target: link_target}, %{
               kind: :install,
               target: data_target
             }] = mise_effects

      assert config_target == @config_target
      assert link_target == @link_target
      assert data_target == @data_target

      assert [install] = Enum.filter(mise_effects, &(&1.kind == :install))
      assert install.target == @data_target
      assert install.tools == tools
      assert install.mise_target == @mise_target
      assert install.mise_version == @mise_version
      assert hd(mise_effects).fingerprint == Mise.fingerprint_tools(tools)
    end

    test "the fold orders the binary download before the managed-tool effects" do
      plan = build_plan()

      contracts =
        Pipeline.effects(plan) |> Enum.map(& &1.contract) |> Enum.uniq()

      # Contract ids sort the fold: the pinned binary lands before the tools
      # that need it, and the staged generation applies last.
      assert contracts == ["download", "mise", "chezmoi"]

      assert [%{contract: "download"}, %{contract: "mise"} | _] = Pipeline.effects(plan)
    end

    test "a catalog without declarations contributes no mise effects and no descriptor" do
      plan = build_plan(tools: false)
      assert plan.mise == nil
      refute Enum.any?(plan.manifest, &String.starts_with?(&1["name"], "mise/"))
      assert Pipeline.effects(plan) |> Enum.filter(&(&1.contract == "mise")) == []
    end
  end

  describe "effect mechanics (injected runner)" do
    test "configure writes the composed bytes and absorbs the installer fragment", %{home: home} do
      File.mkdir_p!(Path.join(home, ".config/mise/conf.d"))
      fragment = Path.join(home, ".config/mise/conf.d/workstation-bootstrap.toml")
      File.write!(fragment, "[tools]\n\"aqua:tmux/tmux-builds\" = \"3.7c\"\n")

      effect = configure_effect()
      assert :ok = Mise.run_effect(effect, %{home: home})

      mise = build_plan().mise
      assert File.read!(Path.join(home, @config_target)) == Mise.config_bytes(mise)
      refute File.exists?(fragment)

      # Idempotent: identical bytes are a no-op and a second run stays clean.
      assert :ok = Mise.run_effect(effect, %{home: home})
      assert File.read!(Path.join(home, @config_target)) == Mise.config_bytes(mise)
    end

    test "configure refuses to delete a conf.d fragment that is not a plain file", %{home: home} do
      File.mkdir_p!(Path.join([home, ".config/mise/conf.d", "workstation-bootstrap.toml"]))

      assert_raise ArgumentError, ~r/exists as directory/, fn ->
        Mise.run_effect(configure_effect(), %{home: home})
      end
    end

    test "link creates the PATH symlink; a stale link converges", %{home: home} do
      install_fake_mise(home)

      assert :ok = Mise.run_effect(link_effect(), %{home: home})
      assert {:ok, "../opt/mise/2026.10.8/bin/mise"} = File.read_link(Path.join(home, @link_target))

      File.rm(Path.join(home, @link_target))
      File.ln_s!("../opt/mise/other/bin/mise", Path.join(home, @link_target))

      assert :ok = Mise.run_effect(link_effect(), %{home: home})
      assert {:ok, "../opt/mise/2026.10.8/bin/mise"} = File.read_link(Path.join(home, @link_target))
    end

    test "link absorbs the installer's first-acquisition copy by content proof", %{home: home} do
      install_fake_mise(home)
      File.mkdir_p!(Path.dirname(Path.join(home, @link_target)))
      File.write!(Path.join(home, @link_target), fake_mise_bytes())

      assert :ok = Mise.run_effect(link_effect(), %{home: home, plan: plan_with_mise(build_plan().mise)})
      assert {:ok, "../opt/mise/2026.10.8/bin/mise"} = File.read_link(Path.join(home, @link_target))
    end

    test "link refuses a foreign file at the PATH target", %{home: home} do
      install_fake_mise(home)
      File.mkdir_p!(Path.dirname(Path.join(home, @link_target)))
      File.write!(Path.join(home, @link_target), "not the installer's mise")

      assert_raise ArgumentError, ~r/sha256 mismatch/, fn ->
        Mise.run_effect(link_effect(), %{home: home, plan: plan_with_mise(build_plan().mise)})
      end

      assert File.read!(Path.join(home, @link_target)) == "not the installer's mise"
    end

    test "install runs one pinned invocation and probes every tool through mise", %{home: home} do
      install_fake_mise(home)
      calls = agent()

      runner = fn exe, args, env ->
        Agent.update(calls, &(&1 ++ [{exe, args, env}]))

        case args do
          ["install" | _] -> {"installed", 0}
          ["where", _spec] -> {"/data/installs", 0}
        end
      end

      assert :ok = Mise.run_effect(install_effect(), %{home: home, mise: runner})

      # Composed order: the sorted tool pins ride one invocation, the
      # resolution probes follow in the same order.
      assert [{exe, ["install", "github:aristocratos/btop@1.4.7", "aqua:tmux/tmux-builds@3.7c"], env} | probes] =
               Agent.get(calls, & &1)

      assert exe == Path.join(home, @mise_target)
      assert env["MISE_DATA_DIR"] == Path.join(home, @data_target)
      assert env["MISE_CONFIG_DIR"] == Path.join(home, ".config/mise")
      assert env["HOME"] == home

      assert Enum.map(probes, &elem(&1, 1)) == [
               ["where", "github:aristocratos/btop@1.4.7"],
               ["where", "aqua:tmux/tmux-builds@3.7c"]
             ]
    end

    test "install fails closed when the pinned binary is absent", %{home: home} do
      assert_raise ArgumentError, ~r/pinned mise binary .* is absent/, fn ->
        Mise.run_effect(install_effect(), %{home: home, mise: fn _exe, _args, _env -> {"", 0} end})
      end
    end

    test "install refuses when the resolution probe fails — a missing pin is drift", %{home: home} do
      install_fake_mise(home)

      runner = fn _exe, args, _env ->
        case args do
          ["install" | _] -> {"installed", 0}
          ["where", "github:aristocratos/btop@1.4.7"] -> {"mise ERROR not installed", 1}
        end
      end

      assert_raise ArgumentError, ~r/does not resolve at the pinned version/, fn ->
        Mise.run_effect(install_effect(), %{home: home, mise: runner})
      end
    end
  end

  describe "journal claims" do
    test "configure claims the composed file; link claims the link; install claims the tool state", %{home: home} do
      install_fake_mise(home)
      mise = build_plan().mise
      runner = probing_runner()

      assert :ok = Mise.run_effect(configure_effect(), %{home: home})
      assert :ok = Mise.run_effect(link_effect(), %{home: home})
      assert :ok = Mise.run_effect(install_effect(), %{home: home, mise: runner})

      File.mkdir_p!(Path.join(home, @data_target))

      ctx = %{home: home, plan: plan_with_mise(mise)}

      claims = Mise.fingerprint(configure_effect(), ctx)
      config_record = Map.fetch!(claims, @config_target)
      assert config_record["type"] == "file"
      assert config_record["sha256"] == Digest.sha256(Mise.config_bytes(mise))
      assert config_record["owner"] == "mise"
      assert config_record["operation"] == "configure"

      link_record = Map.fetch!(Mise.fingerprint(link_effect(), ctx), @link_target)
      assert link_record["type"] == "link"
      assert link_record["link"] == "../opt/mise/2026.10.8/bin/mise"
      assert link_record["operation"] == "link"

      install_record = Map.fetch!(Mise.fingerprint(install_effect(), %{home: home, mise: runner}), @data_target)
      assert install_record["type"] == "mise"
      assert install_record["mise"] == @mise_target
      assert install_record["mise_version"] == @mise_version
      assert install_record["tools"] == [
               %{"backend" => "github:aristocratos/btop", "name" => "btop", "version" => "1.4.7"},
               %{"backend" => "aqua:tmux/tmux-builds", "name" => "tmux", "version" => "3.7c"}
             ]

      assert install_record["operation"] == "install"
      assert install_record["source_fingerprint"] == Mise.fingerprint_tools(mise.tools)
    end

    test "a configure claim whose bytes diverge from the composition refuses", %{home: home} do
      File.mkdir_p!(Path.dirname(Path.join(home, @config_target)))
      File.write!(Path.join(home, @config_target), "tampered\n")

      assert_raise ArgumentError, ~r/did not produce the managed mise config/, fn ->
        Mise.fingerprint(configure_effect(), %{home: home})
      end
    end
  end

  describe "the verify seam" do
    test "a mise record re-checks every tool through mise; other records are unclaimed", %{home: home} do
      install_fake_mise(home)

      record = %{
        "type" => "mise",
        "mise" => @mise_target,
        "mise_version" => @mise_version,
        "tools" => [
          %{"backend" => "aqua:tmux/tmux-builds", "name" => "tmux", "version" => "3.7c"}
        ]
      }

      ok_runner = fn _exe, ["where", _spec], _env -> {"/data/installs", 0} end
      assert :ok = Mise.verify_record(record, %{"home" => home, "mise_runner" => ok_runner})

      assert :unclaimed = Mise.verify_record(%{"type" => "file", "sha256" => "x"}, %{"home" => home})
    end

    test "drift refusal: a changed version under an unchanged record fails closed", %{home: home} do
      install_fake_mise(home)

      record = %{
        "type" => "mise",
        "mise" => @mise_target,
        "mise_version" => @mise_version,
        "tools" => [
          %{"backend" => "aqua:tmux/tmux-builds", "name" => "tmux", "version" => "3.7c"}
        ]
      }

      drifted_runner = fn _exe, ["where", "aqua:tmux/tmux-builds@3.7c"], _env ->
        {"mise ERROR aqua:tmux/tmux-builds@3.7c not installed", 1}
      end

      assert_raise ArgumentError, ~r/does not resolve at the pinned version/, fn ->
        Mise.verify_record(record, %{"home" => home, "mise_runner" => drifted_runner})
      end

      assert_raise ArgumentError, ~r/pinned mise binary .* is gone/, fn ->
        Mise.verify_record(record, %{"home" => home <> "-empty", "mise_runner" => probing_runner()})
      end
    end

    test "a mise record without its claim is corruption" do
      assert_raise ArgumentError, ~r/record is corruption/, fn ->
        Mise.verify_record(%{"type" => "mise"}, %{"home" => "/tmp"})
      end
    end
  end

  describe "full pipeline execute (the fold discovers the contract)" do
    test "the plan applies through the fold with injected fetch and runner, and records the claims", %{home: home} do
      install_fake_chezmoi(home)
      plan = build_plan()

      runner = fn _exe, args, _env ->
        case args do
          ["install" | _] ->
            File.mkdir_p!(Path.join([home, @data_target, "installs"]))
            {"installed", 0}

          ["where", _spec] ->
            {"/data/installs", 0}
        end
      end

      opts = %{
        "home" => home,
        "fetch" => fn _url -> @fake_mise end,
        "mise" => runner
      }

      assert Pipeline.execute(plan, opts) == plan.generation

      state_root = Path.join([home | EngineState.state_components()])
      applied = Journal.applied(state_root)
      assert applied["generation"] == plan.generation

      # The binary pin claimed by the download contract, the three surfaces
      # claimed by the mise contract, in one applied record.
      assert applied["targets"][@mise_target]["sha256"] == @mise_sha

      assert %{
               "type" => "mise",
               "mise" => @mise_target,
               "operation" => "install"
             } = applied["targets"][@data_target]

      assert applied["targets"][@config_target]["type"] == "file"
      assert applied["targets"][@config_target]["sha256"] == Digest.sha256(Mise.config_bytes(plan.mise))
      assert applied["targets"][@link_target]["type"] == "link"
      assert applied["targets"][@link_target]["link"] == "../opt/mise/2026.10.8/bin/mise"
      assert Journal.pending(state_root) == []

      # Re-applying the identical desired generation is the idempotent no-op.
      assert Pipeline.execute(plan, opts) == plan.generation
      assert Journal.applied(state_root)["revision"] == 2
    end
  end

  # --- helpers ---

  defp agent do
    {:ok, pid} = Agent.start_link(fn -> [] end)
    pid
  end

  defp probing_runner do
    fn _exe, ["install" | _], _env -> {"installed", 0}
      _exe, ["where", _spec], _env -> {"/data/installs", 0} end
  end

  # A stand-in pinned binary; effects only lstat it (the download contract
  # owns the content verification) and the injected runner never executes it.
  defp install_fake_mise(home) do
    path = Path.join(home, @mise_target)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, @fake_mise)
    File.chmod!(path, 0o755)
  end

  defp fake_mise_bytes, do: @fake_mise

  defp mise_pin do
    %{
      owner: "mise-foundation-goldens",
      target: @mise_target,
      version: @mise_version,
      assets: %{
        "linux_x86_64" => %{url: "https://goldens.invalid/mise/mise-v2026.10.8-linux-x64", sha256: @mise_sha},
        "darwin_arm64" => %{url: "https://goldens.invalid/mise/mise-v2026.10.8-macos-arm64", sha256: @mise_sha}
      }
    }
  end

  defp configure_effect do
    mise = build_plan().mise

    %{
      contract: "mise",
      kind: :configure,
      phase: :target,
      target: @config_target,
      tools: mise.tools,
      owners: mise.owners,
      fingerprint: mise.fingerprint
    }
  end

  defp link_effect do
    mise = build_plan().mise

    %{
      contract: "mise",
      kind: :link,
      phase: :target,
      target: @link_target,
      mise_target: @mise_target,
      mise_version: @mise_version,
      fingerprint: mise.fingerprint
    }
  end

  defp install_effect do
    mise = build_plan().mise

    %{
      contract: "mise",
      kind: :install,
      phase: :target,
      target: @data_target,
      tools: mise.tools,
      mise_target: @mise_target,
      mise_version: @mise_version,
      fingerprint: mise.fingerprint
    }
  end

  # The synthetic mise golden envelope through the real composition — the
  # same string-keyed shape the committed goldens pin (download pin package
  # plus a tools declarer; no entries, no shell fragments).
  defp build_plan(opts \\ []) do
    tools? = Keyword.get(opts, :tools, true)

    packages = [
      %{
        "id" => "mise-foundation-goldens",
        "requires" => [],
        "contributes" => [
          %{
            "provider" => "download",
            "spec" => %{
              "version" => @mise_version,
              "target" => @mise_target,
              "assets" => %{
                "linux_x86_64" => %{
                  "url" => "https://goldens.invalid/mise/mise-v2026.10.8-linux-x64",
                  "sha256" => @mise_sha
                },
                "darwin_arm64" => %{
                  "url" => "https://goldens.invalid/mise/mise-v2026.10.8-macos-arm64",
                  "sha256" => @mise_sha
                }
              }
            }
          }
        ]
      }
    ]

    packages =
      if tools? do
        packages ++
          [
            %{
              "id" => "mise-tools-goldens",
              "requires" => [],
              "contributes" => [
                %{
                  "provider" => "mise",
                  "spec" => %{
                    "tools" => [
                      %{"name" => "tmux", "version" => "3.7c", "backend" => "aqua:tmux/tmux-builds"},
                      %{"name" => "btop", "version" => "1.4.7", "backend" => "github:aristocratos/btop"}
                    ]
                  }
                }
              ]
            }
          ]
      else
        packages
      end

    catalog = Catalog.load(%{"profile" => "mise-test", "host" => "linux", "home" => Catalog.canonical_home(), "packages" => packages, "assets" => %{}})
    graph = Graph.order(%{host: catalog.host, specifications: catalog.packages})
    Source.plan(%{graph: graph})
  end

  defp plan_with_mise(mise), do: %{build_plan() | mise: mise}

  # A fake chezmoi at the backend's canonical opt path (the engine resolves
  # the binary there, never from PATH); the plan carries no entries, so the
  # staged apply is an empty no-op.
  defp install_fake_chezmoi(home) do
    bin = Path.join([home, ".local", "opt", "chezmoi", "bin", "chezmoi"])
    File.mkdir_p!(Path.dirname(bin))
    File.write!(bin <> ".instructions", "exit 0\n")

    File.write!(
      bin,
      "#!/bin/sh\nfor arg in \"$@\"; do printf '%s\\n' \"$arg\" >> \"#{bin}.argv\"; done\nsh \"#{bin}.instructions\"\n"
    )

    File.chmod!(bin, 0o755)
    bin
  end
end
