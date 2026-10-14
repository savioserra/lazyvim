defmodule Workstation.Core.ContextTest do
  @moduledoc """
  The package-context API (compose-stage, static layer): declaration
  validation (one export per own-capability, pure string-keyed values,
  requires keyed to declared dependencies, version ranges), the
  compose-stage topological fold with dependency-scoped visibility, and the
  two-layer separation from the dynamic effect layer — the context is a
  pure function of (manifests, resolver order) and can never see effect
  results.
  """

  use ExUnit.Case, async: true

  alias Workstation.Core.Catalog
  alias Workstation.Core.Catalog.Spec
  alias Workstation.Core.{Graph, Source}

  @theme_export %{
    key: "goldens-theme",
    schema: 1,
    value: %{"appearance" => "dark", "roles" => ["base", "accent"]}
  }

  describe "declaration validation (fail-closed at the declaration)" do
    test "an export key must be the package's own capability namespace" do
      assert_raise ArgumentError, ~r/must be the package's own capability namespace/, fn ->
        Spec.validate_exports([%{key: "other", schema: 1, value: %{}}, :ok] |> Enum.take(1), "mine")
      end
    end

    test "export values are pure string-keyed data — no functions, refs or atom-keyed maps" do
      assert Spec.validate_exports([%{key: "mine", schema: 1, value: %{"ok" => ["a", 1, true, nil]}}], "mine") == :ok

      assert_raise ArgumentError, ~r/pure string-keyed data/, fn ->
        Spec.validate_exports([%{key: "mine", schema: 1, value: %{"bad" => fn -> :world end}}], "mine")
      end

      assert_raise ArgumentError, ~r/pure string-keyed data/, fn ->
        Spec.validate_exports([%{key: "mine", schema: 1, value: %{"bad" => %{atom_key: 1}}}], "mine")
      end

      assert_raise ArgumentError, ~r/pure string-keyed data/, fn ->
        Spec.validate_exports([%{key: "mine", schema: 1, value: self()}], "mine")
      end
    end

    test "a context_require must name a declared dependency (least knowledge)" do
      assert_raise ArgumentError, ~r/must name a capability provided by one of/, fn ->
        Spec.validate_context_requires([%{key: "undeclared", schema: 1, in_requires: false}], "consumer")
      end

      assert Spec.validate_context_requires([%{key: "dep", schema: ">=1", in_requires: true}], "consumer") == :ok
    end

    test "schema ranges must be well-formed" do
      assert_raise ArgumentError, ~r/schema must be a positive integer or a constraint string/, fn ->
        Spec.validate_context_requires([%{key: "dep", schema: "latest", in_requires: true}], "consumer")
      end
    end
  end

  describe "schema ranges" do
    test "integer ranges pin exactly; constraint strings compose" do
      assert Spec.schema_covered?(1, 1)
      refute Spec.schema_covered?(2, 1)
      assert Spec.schema_covered?(1, ">=1 <2")
      refute Spec.schema_covered?(2, ">=1 <2")
      assert Spec.schema_covered?(3, ">=1")
      assert Spec.schema_covered?(1, "1")
      refute Spec.schema_covered?(2, "1")
    end

    test "malformed ranges fail closed" do
      assert_raise ArgumentError, ~r/invalid schema range constraint/, fn ->
        Spec.schema_covered?(1, "~> 1.0")
      end

      assert_raise ArgumentError, ~r/schema range must not be empty/, fn ->
        Spec.schema_covered?(1, "   ")
      end
    end
  end

  describe "the compose-stage fold" do
    test "a consumer's resolved view is dependency-scoped: only declared keys, only their data" do
      plan = plan_for([
        provider_spec("goldens-theme", 1, %{"appearance" => "dark"}),
        provider_spec("goldens-editor", 1, %{"name" => "goldens-nvim"}),
        consumer_spec("goldens-consumer", ["goldens-theme", "goldens-editor"],
                      context_requires: ["goldens-theme"])
      ])

      assert plan.context == %{
               "goldens-consumer" => %{
                 "goldens-theme" => %{key: "goldens-theme", schema: 1, value: %{"appearance" => "dark"}}
               }
             }
    end

    test "the fold is a pure function of (manifests, resolver order): same graph, byte-identical context" do
      specs = [
        provider_spec("goldens-theme", 1, %{"appearance" => "dark"}),
        consumer_spec("goldens-consumer", ["goldens-theme"], context_requires: ["goldens-theme"])
      ]

      assert Source.plan(%{graph: graph(specs)}).context == Source.plan(%{graph: graph(specs)}).context
    end

    test "a schema-range miss fails closed at compose, naming package and key" do
      assert_raise ArgumentError, ~r/goldens-consumer context_requires goldens-theme schema ">=2" does not cover/, fn ->
        plan_for([
          provider_spec("goldens-theme", 1, %{"appearance" => "dark"}),
          consumer_spec("goldens-consumer", ["goldens-theme"], context_requires: ["goldens-theme"], schema: ">=2")
        ])
      end
    end

    test "a context_require on a dependency that exports nothing fails closed at compose" do
      assert_raise ArgumentError,
                   ~r/goldens-consumer context_requires goldens-mute, but no dependency exports that key/,
                   fn ->
        plan_for([
          provider_spec("goldens-mute", nil, nil),
          consumer_spec("goldens-consumer", ["goldens-mute"], context_requires: ["goldens-mute"])
        ])
      end
    end

    test "packages without context requirements carry no view (the world context never leaks)" do
      plan =
        plan_for([
          provider_spec("goldens-theme", 1, %{"appearance" => "dark"}),
          consumer_spec("goldens-consumer", ["goldens-theme"], context_requires: ["goldens-theme"]),
          provider_spec("goldens-bystander", nil, nil)
        ])

      assert Map.has_key?(plan.context, "goldens-consumer")
      refute Map.has_key?(plan.context, "goldens-theme")
      refute Map.has_key?(plan.context, "goldens-bystander")
    end
  end

  describe "two-layer separation from the dynamic effect layer" do
    test "the resolved context carries exactly the declared export data — never effect results" do
      specs = [
        provider_spec("goldens-theme", 1, %{"appearance" => "dark"}),
        consumer_spec("goldens-consumer", ["goldens-theme"], context_requires: ["goldens-theme"])
      ]

      plan = Source.plan(%{graph: graph(specs)})

      # Structural: every context value deep-equals a DECLARED export value.
      # Effect results (an installed artifact path, a clone dir) are produced
      # by run_effect returns in the interpret fold — a different stage, a
      # different channel — so nothing declared here can be a runtime fact.
      Enum.each(plan.context, fn {_consumer, keys} ->
        Enum.each(keys, fn {_key, entry} ->
          declared =
            specs
            |> Enum.flat_map(&List.wrap(Map.get(&1, :exports) || []))
            |> Enum.find(&(&1.key == entry.key and &1.schema == entry.schema))

          assert entry.value == declared.value
        end)
      end)
    end
  end

  describe "recorded-envelope round-trip" do
    test "exports and context_requires survive the recorded envelope byte-shape" do
      input = %{
        "profile" => "context-probe",
        "host" => "linux",
        "home" => "/home/golden",
        "packages" => [
          %{
            "id" => "goldens-theme",
            "requires" => [],
            "exports" => [%{"key" => "goldens-theme", "schema" => 1, "value" => %{"appearance" => "dark"}}],
            "contributes" => []
          },
          %{
            "id" => "goldens-consumer",
            "requires" => ["goldens-theme"],
            "context_requires" => [%{"key" => "goldens-theme", "schema" => ">=1"}],
            "contributes" => []
          }
        ],
        "assets" => []
      }

      catalog = Catalog.load(input)
      graph = Graph.order(%{host: catalog.host, specifications: catalog.packages})
      plan = Source.plan(%{graph: graph})

      assert %{
               "goldens-consumer" => %{
                 "goldens-theme" => %{schema: 1, value: %{"appearance" => "dark"}}
               }
             } = plan.context
    end
  end

  ## fixtures

  defp graph(specs), do: Graph.order(%{host: "linux", specifications: specs})

  defp plan_for(specs), do: Source.plan(%{graph: graph(specs)})

  defp provider_spec(id, schema, value) do
    exports = if schema, do: [%{key: id, schema: schema, value: value || %{}}], else: []

    %{id: id, requires: [], supported_hosts: nil, contributes: []}
    |> put_exports(exports)
  end

  defp consumer_spec(id, requires, opts) do
    schema = Keyword.get(opts, :schema, ">=1")

    context_requires =
      opts
      |> Keyword.fetch!(:context_requires)
      |> Enum.map(fn key -> %{key: key, schema: schema, in_requires: key in requires} end)

    %{id: id, requires: requires, supported_hosts: nil, contributes: []}
    |> Map.put(:context_requires, context_requires)
  end

  defp put_exports(spec, []), do: spec
  defp put_exports(spec, exports), do: Map.put(spec, :exports, exports)
end
