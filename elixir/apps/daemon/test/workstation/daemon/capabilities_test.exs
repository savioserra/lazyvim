defmodule Workstation.Daemon.CapabilitiesTest do
  use ExUnit.Case, async: false

  alias Workstation.Daemon.{Application, Capabilities, Protocol}
  alias Workstation.Daemon.Capabilities.Assembly

  @infrastructure [
    Workstation.Daemon.Listener,
    Workstation.Daemon.Sessions,
    Workstation.Daemon.EventBus,
    Workstation.Daemon.OpRegistry,
    Workstation.Daemon.CapabilityRegistry,
    Workstation.Daemon.ApplyOrchestrator,
    Workstation.Daemon.TaskSupervisor
  ]

  # --- the registry contract --------------------------------------------------

  describe "registry assembly" do
    test "every registry entry implements the capability behaviour" do
      for module <- Capabilities.registry() do
        assert Code.ensure_loaded?(module)
        assert function_exported?(module, :ops, 0)
        assert function_exported?(module, :schema, 1)
        assert function_exported?(module, :handle, 3)
        assert function_exported?(module, :domains, 0)
        assert function_exported?(module, :children, 0)
      end
    end

    test "ops are exactly the union of capability ops; hello rides on top" do
      assert Capabilities.ops() == Enum.sort(Enum.flat_map(Capabilities.registry(), & &1.ops()))
      refute "hello" in Capabilities.ops()

      expected = Enum.sort(["hello" | Capabilities.ops()])
      assert Protocol.ops() == expected
      assert Protocol.capabilities()["ops"] == expected
    end

    test "each op has exactly one owning capability and schema lookup routes to it" do
      for op <- Capabilities.ops() do
        assert {:ok, module} = Capabilities.owner(op)
        assert module in Capabilities.registry()
        assert {:ok, _schema} = Capabilities.schema(op)
      end

      assert {:ok, Workstation.Daemon.Capabilities.Theme} = Capabilities.owner("theme.resolve")
      assert {:ok, Workstation.Daemon.Capabilities.Apply} = Capabilities.owner("apply.run")
      assert {:ok, Workstation.Daemon.Capabilities.Lifecycle} = Capabilities.owner("update.run")
    end
  end

  describe "domains advertisement" do
    test "domains are the union of registered capability domains, sorted" do
      expected = Capabilities.registry() |> Enum.flat_map(& &1.domains()) |> Enum.sort()
      assert Capabilities.domains() == expected
    end

    test "the theme domain is owned by the theme capability and advertised in hello" do
      # Membership, not whole-domain inventory: the full set is pinned by the
      # union-derivation test above, so this contract only needs theme present.
      assert "theme" in Capabilities.domains()
      assert {:ok, Workstation.Daemon.Capabilities.Theme} = Capabilities.domain_owner("theme")

      assert Protocol.capabilities()["domains"] == Capabilities.domains()
    end

    test "domain ownership is exclusive by construction (one owner per name)" do
      owners =
        Capabilities.registry()
        |> Enum.flat_map(fn module -> Enum.map(module.domains(), fn d -> {d, module} end) end)
        |> Enum.group_by(fn {domain, _module} -> domain end)

      assert Enum.all?(owners, fn {_domain, owner} -> length(owner) == 1 end)
    end
  end

  describe "children ordering" do
    test "capability children flatten in registration order after the infrastructure" do
      assert Application.children() == @infrastructure ++ Capabilities.children()
    end

    test "every capability child starts after CapabilityRegistry (rest_for_one)" do
      children = Application.children()
      registry_index = Enum.find_index(children, &(&1 == Workstation.Daemon.CapabilityRegistry))

      for child <- Capabilities.children() do
        index = Enum.find_index(children, &(&1 == child))
        assert index > registry_index, "capability child #{inspect(child)} must not precede the registry"
      end
    end

    test "the overlay pubsub server is a capability child" do
      # Membership is the contract; the exact child list is pinned by the
      # infrastructure++children ordering test above.
      assert Workstation.Daemon.Overlay in Capabilities.children()
    end
  end

  describe "dispatch" do
    # The theme capability publishes on the overlay domain as part of its
    # resolve, so the dispatch tests boot the overlay primitive — and the
    # event bus its pub fanout needs (same :rest_for_one order as the
    # daemon tree).
    setup do
      start_supervised!(Workstation.Daemon.EventBus)
      start_supervised!(Workstation.Daemon.Overlay)
      :ok
    end

    test "unknown ops refuse with the unchanged protocol refusal" do
      refusal = Protocol.unknown_op()
      assert refusal == {"unknown_op", "op is not served by this daemon"}
      assert {:error, ^refusal} = Capabilities.dispatch("nope", %{}, nil)
      assert {:error, ^refusal} = Capabilities.schema("nope")
    end

    test "theme.resolve dispatches to the theme capability and returns its result" do
      params = %{"appearance" => "dark", "overlays" => []}

      assert {:ok, %{"appearance" => "dark", "colors" => colors}} =
               Capabilities.dispatch("theme.resolve", params, nil)

      assert Map.has_key?(colors, "accent")
    end

    test "handler refusals pass through unchanged" do
      assert {:error, {"invalid_params", message}} =
               Capabilities.dispatch("theme.resolve", %{"appearance" => "weird"}, nil)

      assert message =~ "appearance"
    end
  end

  # --- compile-time duplicate detection ---------------------------------------

  describe "compile-time duplicate detection (Capabilities.Assembly)" do
    defmodule DupOpsA do
      use Workstation.Daemon.Capability

      @impl true
      def ops, do: ["shared.op"]
    end

    defmodule DupOpsB do
      use Workstation.Daemon.Capability

      @impl true
      def ops, do: ["shared.op"]
    end

    defmodule DupDomA do
      use Workstation.Daemon.Capability

      @impl true
      def domains, do: ["shared"]
    end

    defmodule DupDomB do
      use Workstation.Daemon.Capability

      @impl true
      def domains, do: ["shared"]
    end

    test "a duplicate op name across capabilities raises" do
      assert_raise ArgumentError, ~r/duplicate daemon op "shared.op"/, fn ->
        Assembly.op_index!([DupOpsA, DupOpsB])
      end
    end

    test "a duplicate domain name across capabilities raises" do
      assert_raise ArgumentError, ~r/duplicate daemon pubsub domain "shared"/, fn ->
        Assembly.domain_index!([DupDomA, DupDomB])
      end
    end

    test "the production registry assembles cleanly" do
      assert map_size(Assembly.op_index!(Capabilities.registry())) == length(Capabilities.ops())

      assert map_size(Assembly.domain_index!(Capabilities.registry())) ==
               length(Capabilities.domains())
    end
  end
end
