defmodule Workstation.Packages.Typescript do
  @moduledoc """
  The `typescript` workstation package's native contribution:
  the TypeScript language profile intent plus its deployed plugin
  module.

  An explicitly registered language package that requires the Node runtime
  and the nvim editor; it owns its deployed plugin module and its profile
  intent. Behavior verification through the nvim-owned leaf helpers is not
  an engine surface (c4b/c5 record which parts must
  gain Elixir equivalents).
  """

  @behaviour Workstation.Core.Catalog.Spec

  alias Workstation.Core.Catalog.Packages
  alias Workstation.Packages.Nvim.Profile

  @intent %{
    id: "typescript",
    requires: ["node"],
    plugin_module: "languages.plugins.typescript",
    lazyvim_extras: [
      "lazyvim.plugins.extras.lang.typescript",
      "lazyvim.plugins.extras.linting.eslint",
      "lazyvim.plugins.extras.formatting.prettier"
    ],
    mason_packages: ["typescript-language-server", "eslint-lsp", "prettier"],
    language_cases: [
      %{
        language: "javascript",
        filename: "attachment-test.js",
        contents: "const answer = 42;\n",
        client: "typescript-tools"
      }
    ],
    formatter_cases: [
      %{
        language: "javascript",
        filename: "format-test.js",
        contents: "const answer=42\n",
        expected: "const answer = 42;\n",
        project_files: %{".prettierrc.json" => "{}\n"}
      }
    ]
  }

  @spec spec() :: map()
  def spec do
    %{
      foundation: "foundation/runtime",
      id: "typescript",
      requires: ["node", "nvim"],
      supported_hosts: nil,
      contributes: [
        Profile.contribute(20, @intent),
        Packages.chezmoi(
          target: ".config/nvim/lua/languages/plugins/typescript.lua",
          kind: :file,
          asset: "files/languages/plugins/typescript.lua"
        )
      ]
    }
  end
end
