defmodule Workstation.Core.Catalog.Packages.ElixirLang do
  @moduledoc """
  The `elixir` workstation package's native contribution:
  the Elixir/HEEx editor integration on top of the nvim capability.

  The BEAM toolchain (elixir/erlang resolvable on PATH, mise- or
  system-managed) is a host prerequisite, not an engine-owned runtime: there
  is no elixir runtime capability yet, so this package is one step looser
  than typescript, whose Node toolchain the node capability owns end to end.
  Formatting is pinned to the deterministic `mix format` CLI through conform;
  the formatter case therefore needs a minimal mix project, not just a bare
  source file. The module is named ElixirLang (not Elixir) because the
  language's own module namespace must never collide with the host language.
  """

  alias Workstation.Core.Catalog.Packages

  @intent %{
    id: "elixir",
    plugin_module: "languages.plugins.elixir",
    lazyvim_extras: [
      "lazyvim.plugins.extras.lang.elixir"
    ],
    mason_packages: ["elixir-ls"],
    language_cases: [
      %{
        language: "elixir",
        filename: "behavior-test.ex",
        contents: "defmodule Behavior do\n  def answer, do: 42\nend\n",
        # The lspconfig server name, not the Mason package name: Mason ships
        # "elixir-ls" while the attached client calls itself "elixirls".
        client: "elixirls"
      }
    ],
    formatter_cases: [
      %{
        language: "elixir",
        filename: "format-test.ex",
        contents: "defmodule T do\ndef answer do\n42\nend\nend\n",
        expected: "defmodule T do\n  def answer do\n    42\n  end\nend\n",
        project_files: %{
          "mix.exs" => """
          defmodule FormatTest.MixProject do
            use Mix.Project

            def project do
              [app: :format_test, version: "0.1.0"]
            end
          end
          """
        }
      }
    ]
  }

  @spec spec() :: map()
  def spec do
    %{
      foundation: "foundation/runtime",
      id: "elixir",
      requires: ["nvim"],
      supported_hosts: nil,
      contributes: [
        Packages.profile_intent(25, @intent),
        Packages.chezmoi(
          target: ".config/nvim/lua/languages/plugins/elixir.lua",
          kind: :file,
          asset: "files/languages/plugins/elixir.lua"
        )
      ]
    }
  end
end
