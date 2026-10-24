defmodule Workstation.Core.LayerLawTest do
  @moduledoc """
  The layer law of docs/architecture.md, per namespace, as source scans —
  plus the proof that the scans can fail.

  Layers (docs/architecture.md): kernel (generic machinery, names no
  package/backend/consumer) <- platform engines (consumers derive, never
  named). The contracts, backends and package layers retired with the
  manifest format (docs/absorption.md, stage 2) — the laws that guarded
  their seams retired with them. These tests enforce:

    1. Kernel namespace scans: no consumer/backend name anywhere in the
       kernel (herdr/pi/tmux2k nowhere, chezmoi nowhere — the dialect has
       no speaker).
    2. The theme platform never names a consumer (covered in depth by
       `ArchitectureDepsTest`; asserted here against the kernel set too).

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

  describe "kernel namespace law" do
    test "kernel files name no consumer/backend anywhere in code" do
      for rel <- kernel_files() do
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

    test "kernel never statically imports the consumer namespace" do
      for rel <- kernel_files() do
        violations = kernel_package_import_violations(read(rel))

        assert violations == [],
               "#{rel} statically imports the consumer namespace #{inspect(violations)}"
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

  # -- Self-test: planted violations must be detected, sanctioned forms and
  # -- clean text must pass. Fixtures are synthetic; none occur in this repo.
  describe "scanner self-test (the tester can fail)" do
    test "consumer scanner detects a planted consumer name and passes clean text" do
      planted = ~s(defp config, do: "watch herdr sessions and tmux panics")
      assert consumer_violations(planted) != []
      assert consumer_violations("watch the terminal sessions and panics") == []
    end

    test "backend scanner detects a planted raw mention, passes sanctioned API forms" do
      planted = ~s(def provider, do: "chezmoi")
      assert backend_literal_violations(planted) != []

      sanctioned =
        [
          "# history: the old chezmoi literal lived here (comment lines are law-free)",
          ~s(@moduledoc """),
          "The chezmoi dialect died with the backend that owned it.",
          ~s("""),
          "def other, do: :ok"
        ]
        |> Enum.join("\n")

      assert backend_literal_violations(sanctioned) == []
    end

    test "package-import scanner detects a planted kernel import, passes clean code" do
      planted = "alias Workstation.Packages.Nvim"
      assert kernel_package_import_violations(planted) != []

      planted_moved = "alias Workstation.Packages.Nvim.Profile"
      assert kernel_package_import_violations(planted_moved) != []

      assert kernel_package_import_violations("alias Workstation.Core.Report") == []
    end

    test "the scanners are the shared primitives the tree scans use" do
      # Detection power transfers only if both suites call the same code:
      # assert the exported surface the suites rely on really exists.
      assert function_exported?(ArchitectureLaw, :consumer_violations, 1)
      assert function_exported?(ArchitectureLaw, :backend_literal_violations, 1)
      assert function_exported?(ArchitectureLaw, :kernel_package_import_violations, 1)
      assert function_exported?(ArchitectureLaw, :code_lines, 1)
    end
  end

  # The kernel scan set: the Workstation.Core namespace.
  defp kernel_files do
    Path.wildcard(Path.join(@elixir_root, "apps/core/lib/workstation/core/**/*.ex"))
    |> Enum.map(&Path.relative_to(&1, @elixir_root))
  end

  defp read(rel), do: File.read!(Path.join(@elixir_root, rel))
end
