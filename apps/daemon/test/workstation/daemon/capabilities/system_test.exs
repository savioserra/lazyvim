defmodule Workstation.Daemon.Capabilities.SystemTest do
  use ExUnit.Case, async: false

  alias Workstation.Daemon.{Capabilities, EventBus, Overlay}

  # EventBus starts before Overlay: pub/2 fans every domain event out on
  # the bus' {:domain, name} topic, and the daemon tree orders them the
  # same way (:rest_for_one).
  setup do
    start_supervised!(EventBus)
    start_supervised!(Overlay)
    :ok
  end

  test "the system capability owns and registers the system domain" do
    assert Capabilities.domain_owner("system") == {:ok, Capabilities.System}
    assert Capabilities.System.domains() == ["system"]
    assert Capabilities.System.ops() == ["system.applied"]
    assert "system.applied" in Capabilities.ops()
    assert "system" in Capabilities.domains()
  end

  test "handle publishes the applied generation on its domain and returns the record" do
    assert Overlay.claim("system", self()) == :ok

    assert {:ok, record} =
             Capabilities.System.handle("system.applied", %{"generation" => 7, "rollback_generation" => 6}, nil)

    assert record == %{
             "type" => "system.applied",
             "domain" => "system",
             "generation" => 7,
             "rollback_generation" => 6,
             "message" => "generation 7 applied (rollback available at 6)"
           }

    assert_receive {:system_applied, ^record}
  end

  test "a first-ever switch (no rollback generation) publishes the standing record" do
    assert Overlay.claim("system", self()) == :ok

    assert {:ok, record} = Capabilities.System.handle("system.applied", %{"generation" => 1}, nil)

    assert record["rollback_generation"] == nil
    assert record["message"] == "generation 1 applied (no prior generation)"

    assert_receive {:system_applied, ^record}
  end

  test "the schema refuses non-positive, non-integer and unknown-key params" do
    {:ok, schema} = Capabilities.schema("system.applied")

    assert {:error, _} = Zoi.parse(schema, %{"generation" => 0})
    assert {:error, _} = Zoi.parse(schema, %{"generation" => "7"})
    assert {:error, _} = Zoi.parse(schema, %{"generation" => 7, "extra" => true})
    assert {:error, _} = Zoi.parse(schema, %{})

    assert {:ok, _} = Zoi.parse(schema, %{"generation" => 7})
    assert {:ok, _} = Zoi.parse(schema, %{"generation" => 7, "rollback_generation" => 6})
    # handle assumes schema-validated params (every capability's posture);
    # its guard makes an off-wire garbage call a crash, never a publish.
    assert {:ok, record} = Capabilities.System.handle("system.applied", %{"generation" => 7}, nil)
    assert record["generation"] == 7
  end

  test "publishing is best-effort: no subscriber, no crash" do
    assert {:ok, _record} = Capabilities.System.handle("system.applied", %{"generation" => 3}, nil)
  end

  describe "domain fanout followers" do
    test "a follower observes applied generations without claiming the domain" do
      EventBus.subscribe({:domain, "system"})

      assert {:ok, record} =
               Capabilities.System.handle("system.applied", %{"generation" => 9, "rollback_generation" => 8}, nil)

      assert_receive {:daemon_event, {:domain, "system"}, {:system_applied, ^record}}
      # Follower, not owner: the domain stayed free the whole time.
      assert Overlay.owned_domains() == []
    end
  end

  describe "the eval-report contract (the two-reader drift guard)" do
    # nix/system-domain.nix carries the nix side of the system-domain
    # contract; this suite carries the daemon side. Either reader renaming
    # its half reds HERE, in a plain `mix test`. The nix file is read as
    # the contract SOURCE it is (the eval-report byte guard retired with
    # the walker); the runtime pin is the report the engine's release
    # bakes. The root walk stops at the engine checkout (flake.nix) —
    # robust to `mix test` from the root or inside an app dir.
    @contract_file Path.join(
                     Enum.reduce(1..8, Path.expand(__DIR__), fn _i, d ->
                       if File.exists?(Path.join(d, "flake.nix")), do: d, else: Path.dirname(d)
                     end),
                     "nix/system-domain.nix"
                   )

    test "the nix publish contract names this module's domain, op and message" do
      assert File.exists?(@contract_file), "missing #{@contract_file} — the nix substrate left the tree?"
      source = File.read!(@contract_file)

      assert source =~ ~s(domain = "#{Capabilities.System.domain()}";)
      assert source =~ ~s(op = "#{Capabilities.System.op()}";)
      assert source =~ ~s(eventType = "#{Capabilities.System.op()}";)
      assert source =~ "messageFormat = \"generation N applied (rollback available at M)\""
      assert source =~ ~s(unit = "workstation-daemon.service";)
      for subcommand <- ["apply", "rollback", "sync", "update"] do
        assert source =~ "\"#{subcommand}\""
      end
    end
  end
end
