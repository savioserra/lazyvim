defmodule Workstation.Core.LayerLawTest do
  @moduledoc """
  The layer law of docs/architecture.md, per namespace, as source scans —
  plus the proof that the scans can fail.

  Layers (docs/architecture.md): kernel (generic machinery, names no
  package/backend/consumer) <- contracts (capability surfaces, name no
  concrete implementation) <- backends (own their dialect) <- platform
  engines (consumers derive, never named) <- packages (everything
  concrete). Dependency direction: packages -> contracts -> kernel;
  backends plug into contracts. These tests enforce:

    1. Kernel namespace scans: no package/backend/consumer name outside
       its owning namespace (chezmoi only in the backend module, nvim only
       under the nvim package namespace, tmux2k/herdr/pi nowhere in the
       kernel).
    2. The theme platform never names a consumer (covered in depth by
       `ArchitectureDepsTest`; asserted here against the kernel set too).
    3. Contracts never name a concrete implementation.
    4. Import direction: the kernel never statically imports the package
       layer; packages -> contracts -> kernel only.

  ## Self-test (the tester is tested — no tautologies)

  The final describe plants VIOLATING fixture strings that exist nowhere
  in this repository and asserts each scanner detects them, alongside
  negative controls (sanctioned forms and clean text asserted to pass).
  The scanners under test are the exact functions the tree scans above
  call (shared `Workstation.Core.ArchitectureLaw` primitives), so proven
  detection power on fixtures transfers to the tree scans.
  """

  use ExUnit.Case, async: true

  import Workstation.Core.ArchitectureLaw

  alias Workstation.Core.ArchitectureLaw

  @elixir_root Path.expand("../../../../..", __DIR__)

  # The kernel namespace: generic machinery only. The consumer/registry
  # layer (catalog/**) legitimately names consumers and packages; the
  # backend family and the two justified data files are exempt exactly as
  # in ArchitectureDepsTest (see its synced exemption table).
  @kernel_exempts MapSet.new([
                    "apps/core/lib/workstation/backends/chezmoi.ex",
                    "apps/core/lib/workstation/core/provisioner.ex",
                    "apps/core/lib/workstation/core/shell_program.ex",
                    "apps/core/lib/workstation/core/update/bootstrap.ex",
                    "apps/core/lib/workstation/core/policy.ex",
                    "apps/core/lib/workstation/core/golden.ex"
                  ])

  @contract_files [
    "apps/core/lib/workstation/core/contracts/provider.ex",
    "apps/core/lib/workstation/core/contracts/contract.ex",
    "apps/core/lib/workstation/core/contracts/download.ex",
    "apps/core/lib/workstation/core/contracts/shell.ex"
  ]

  describe "kernel namespace law" do
    test "kernel files name no package/backend/consumer outside its namespace" do
      for rel <- kernel_files(), rel not in @contract_files do
        # The law binds code: docstrings/comments are the architecture's
        # documentation surface, not couplings.
        code = code_lines(read(rel))

        consumer_hits = consumer_violations(code)
        backend_hits = backend_literal_violations(read(rel))

        assert consumer_hits == [] and backend_hits == [],
               "#{rel} violates the kernel namespace law: " <>
                 "consumers=#{inspect(consumer_hits)} backend=#{inspect(backend_hits)}"
      end
    end

    test "kernel never statically imports the package layer" do
      for rel <- kernel_files() do
        violations = kernel_package_import_violations(read(rel))

        assert violations == [],
               "#{rel} statically imports the package layer #{inspect(violations)} — " <>
                 "kernel consumes packages through contracts and discovery only"
      end
    end

    test "generic kernel code references no concrete package module" do
      for rel <- kernel_files(), not String.contains?(rel, "catalog/") do
        violations = concrete_package_violations(read(rel))

        assert violations == [],
               "#{rel} names concrete package modules #{inspect(violations)} — " <>
                 "the registry composition point and discovery namespace are the " <>
                 "only generic touchpoints of the package layer"
      end
    end
  end

  describe "theme platform law" do
    test "the theme platform engine names no consumer anywhere in the kernel set" do
      theme_rels = Enum.filter(kernel_files(), &String.contains?(&1, "theme"))

      for rel <- theme_rels do
        violations = consumer_violations(code_lines(read(rel)))

        assert violations == [],
               "#{rel} names consumers #{inspect(violations)} — consumers derive " <>
                 "from the platform, the platform never learns who consumes it"
      end

      assert length(theme_rels) > 0, "theme platform files must be discovered by the scan"
    end
  end

  describe "contract law" do
    test "contract modules name no concrete implementation" do
      for rel <- @contract_files do
        code = code_lines(read(rel))

        consumer_hits = consumer_violations(code)
        concrete_hits = concrete_package_violations(code)

        assert consumer_hits == [] and concrete_hits == [],
               "#{rel} (a contract) names concrete implementations: " <>
                 "consumers=#{inspect(consumer_hits)} packages=#{inspect(concrete_hits)}"
      end
    end
  end

  # -- Self-test: planted violations must be detected, sanctioned forms and
  # -- clean text must pass. Fixtures are synthetic; none occur in this repo.
  describe "scanner self-test (the tester can fail)" do
    test "consumer scanner detects a planted consumer name and passes clean text" do
      planted = ~s(defp config, do: "watch herdr sessions and tmux panics")
      assert consumer_violations(planted) != []
      assert consumer_violations("watch the terminal sessions and panics") == []
    end

    test "encoding scanner detects every planted encoding token and passes clean text" do
      planted = ~S(names = ["dot_bashrc", "settings_tmpl", "symlink_target", "remove_me"])
      hits = encoding_violations(planted)
      assert "dot_ mapping" in hits
      assert "_tmpl suffix" in hits
      assert "reserved attribute prefix literal" in hits
      assert "reserved remove prefix literal" in hits

      # remove_file is the sanctioned tombstone filename, not an encoding.
      assert encoding_violations(~S(["remove_file"])) == []
      assert encoding_violations(~S(["bashrc", "settings"])) == []
    end

    test "backend scanner detects a planted raw mention, passes sanctioned API forms" do
      planted = ~s(def provider, do: "chezmoi")
      assert backend_literal_violations(planted) != []

      sanctioned =
        [
          "@chezmoi Workstation.Backends.Chezmoi.provider_id()",
          "def name, do: Chezmoi.remove_filename()",
          "# history: the old chezmoi literal lived here (comment lines are law-free)",
          ~s(@moduledoc """),
          "The chezmoi dialect is the backend's own surface.",
          ~s("""),
          "def other, do: :ok"
        ]
        |> Enum.join("\n")

      assert backend_literal_violations(sanctioned) == []
    end

    test "package-import scanner detects a planted kernel import, passes clean code" do
      planted = "alias Workstation.Packages.Nvim"
      assert kernel_package_import_violations(planted) != []

      planted_catalog = "alias Workstation.Core.Catalog.Packages.Nvim"
      assert kernel_package_import_violations(planted_catalog) != []

      assert kernel_package_import_violations("alias Workstation.Core.Contracts.Provider") == []

      # The registry's generic composition call is not a concrete reference.
      assert concrete_package_violations("packages = Catalog.Packages.packages()") == []
      assert concrete_package_violations("spec = Workstation.Packages.packages()") == []

      planted_concrete = "spec = Catalog.Packages.Nvim.profile_intent(10, intent)"
      assert concrete_package_violations(planted_concrete) != []

      planted_moved = "spec = Workstation.Packages.Nvim.Profile.compose(intents)"
      assert concrete_package_violations(planted_moved) != []

      assert concrete_package_violations("@namespace \"Elixir.Workstation.Packages.\"") == []
    end

    test "the scanners are the shared primitives the tree scans use" do
      # Detection power transfers only if both suites call the same code:
      # assert the exported surface the suites rely on really exists.
      assert function_exported?(ArchitectureLaw, :consumer_violations, 1)
      assert function_exported?(ArchitectureLaw, :encoding_violations, 1)
      assert function_exported?(ArchitectureLaw, :backend_literal_violations, 1)
      assert function_exported?(ArchitectureLaw, :concrete_package_violations, 1)
      assert function_exported?(ArchitectureLaw, :kernel_package_import_violations, 1)
      assert function_exported?(ArchitectureLaw, :code_lines, 1)
    end
  end

  # The kernel scan set: the Workstation.Core namespace plus the pipeline
  # (the kernel stage list lives outside it by design — the law must cover
  # it all the same).
  defp kernel_files do
    extras = ["apps/core/lib/workstation/pipeline.ex"]

    (extras ++ Path.wildcard(Path.join(@elixir_root, "apps/core/lib/workstation/core/**/*.ex")))
    |> Enum.map(&Path.relative_to(&1, @elixir_root))
    |> Enum.reject(&String.contains?(&1, "catalog/packages"))
    |> Enum.reject(&MapSet.member?(@kernel_exempts, &1))
  end

  defp read(rel), do: File.read!(Path.join(@elixir_root, rel))
end
