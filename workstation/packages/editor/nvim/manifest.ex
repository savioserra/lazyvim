defmodule Workstation.Packages.Nvim do
  @moduledoc """
  The `nvim` workstation package's native contribution:
  the editor capability — base configuration payload, lockfiles, the
  engine-seeded lazy-lock merge program, and the nvim-owned profile intents
  (Go and the standard language set).

  Composition surface: this module owns its profile compositor directly —
  `Workstation.Packages.Nvim.Profile` validates the intents, fixes
  their explicit domain order, and serializes the composed profile as
  deployed runtime Lua. It plugs into the assembler through the generic
  `Workstation.Core.Contracts.Provider` contract — the engine never names it. The intents' verification semantics are declared
  data: `language_cases`/`formatter_cases` are the LSP and formatter
  behavior checks, `mason_packages` names what the applied Mason lock must
  provide, `lazyvim_extras` selects LazyVim distribution modules, and the
  deployed editor runtime (the managed `lua/config/sync.lua`) runs the
  LazyVim lifecycle targets (lazy-restore,
  lazy-clean, Mason, Tree-sitter) against the deployed profile. Headless
  verification and sync execution stay in the editor's runtime until the
  lifecycle lane ports package verify/sync handlers; this declaration keeps
  their inputs byte-stable and golden-graded.

  The lazy-lock deploy shape is load-bearing: the deployed plugin lockfile is
  engine-seeded, runtime-extended mutable state (Neovim records the active
  spec set, possibly including host-provided specs), so it deploys through
  the `modify` merge program instead of a byte-owned whole-file recipe —
  legitimate runtime rewrites reconcile at the next apply instead of
  conflicting. The merge program is built at declaration time from the
  committed template with the committed `lazy-lock.json` pins embedded
  verbatim, so the seed path is byte-stable.

  The one home-anchored destination (the managed-Neovim launcher symlink)
  anchors at `Workstation.Core.Catalog.canonical_home/0`, mirroring the
  golden recorder's destination pinning; live evaluation re-roots through
  the live-profile branch of `Workstation.Core.Catalog.load/1`.
  """

  @behaviour Workstation.Core.Catalog.Spec

  alias Workstation.Core.Catalog.Packages
  alias Workstation.Packages.Nvim.Profile
  # Manifests load tree-wide before spec/0 ever runs; the compiler cannot
  # see that order, so the late-loaded sibling is declared.
  @compile {:no_warn_undefined, Workstation.Packages.Nvim.Profile}

  @marker "__WORKSTATION_ENGINE_PINS__"

  # nvim owns base editor state; the payload order is the factory's declared
  # contribution order (recorded construction order of the golden envelopes).
  @payload [
    ".gitignore",
    "init.lua",
    "lazyvim.json",
    "mason-lock.json",
    "neoconf.json",
    "stylua.toml",
    "lua/config/autocmds.lua",
    "lua/config/keymaps.lua",
    "lua/config/lazy.lua",
    "lua/config/options.lua",
    "lua/config/sync.lua",
    "lua/plugins/debugging.lua",
    "lua/plugins/editor.lua",
    "lua/plugins/lsp.lua",
    "lua/plugins/mason-lock.lua",
    "lua/plugins/mason.lua",
    "lua/plugins/testing.lua",
    "lua/plugins/theme.lua",
    "lua/plugins/treesitter.lua",
    "lua/plugins/ui.lua"
  ]

  # nvim's own profile intents, in the composed order they declare: Go before
  # the standard language set (TypeScript is contributed by the typescript
  # capability between them, order 20).
  @go_intent %{
    id: "go",
    requires: ["go"],
    lazyvim_extras: ["lazyvim.plugins.extras.lang.go"],
    language_cases: [
      %{
        language: "go",
        filename: "attachment_test.go",
        contents: "package behavior\n\nvar answer = 42\n",
        client: "gopls"
      }
    ]
  }

  @standard_intent %{
    id: "standard",
    lazyvim_extras: [
      "lazyvim.plugins.extras.lang.docker",
      "lazyvim.plugins.extras.lang.json",
      "lazyvim.plugins.extras.lang.markdown",
      "lazyvim.plugins.extras.lang.tailwind",
      "lazyvim.plugins.extras.lang.toml",
      "lazyvim.plugins.extras.lang.yaml"
    ],
    language_cases: [
      %{language: "lua", filename: "attachment-test.lua", contents: "local answer = 42\n", client: "lua_ls"},
      %{
        language: "html",
        filename: "attachment-test.html",
        contents: "<!doctype html><title>test</title>\n",
        client: "html"
      },
      %{language: "css", filename: "attachment-test.css", contents: "body { color: red; }\n", client: "cssls"},
      %{language: "json", filename: "attachment-test.json", contents: "{ \"answer\": 42 }\n", client: "jsonls"},
      %{language: "yaml", filename: "attachment-test.yaml", contents: "answer: 42\n", client: "yamlls"},
      %{language: "markdown", filename: "attachment-test.md", contents: "# Behavior test\n", client: "marksman"},
      %{language: "dockerfile", filename: "Dockerfile", contents: "FROM scratch\n", client: "dockerls"}
    ]
  }

  @spec spec() :: map()
  def spec do
    lazy_lock_program = build_lazy_lock_program()

    contributes =
      [
        # The managed editor itself: the launcher resolves to bootstrap's
        # pinned installation under the engine-owned opt root.
        Packages.chezmoi(
          target: ".local/bin/nvim",
          kind: :symlink,
          to: Workstation.Core.Catalog.canonical_home() <> "/.local/opt/nvim/bin/nvim"
        ),
        Packages.chezmoi(
          target: ".config/nvim/lazy-lock.json",
          kind: :modify,
          executable: true,
          content: lazy_lock_program
        )
      ] ++
        Enum.map(@payload, fn name ->
          Packages.chezmoi(
            target: ".config/nvim/" <> name,
            kind: :file,
            asset: "files/.config/nvim/" <> name
          )
        end) ++
        [Profile.contribute(10, @go_intent), Profile.contribute(30, @standard_intent)]

    %{
      foundation: "foundation/editor",
      id: "nvim",
      requires: ["foundation", "node", "go"],
      supported_hosts: nil,
      contributes: contributes
    }
  end

  # The modify program seeds the engine pin baseline verbatim: the committed
  # template carries the marker exactly once and the committed pins asset is
  # embedded at that position; the replace hits the first occurrence only —
  # the single-marker semantics the deployed init.lua template carries.
  # Both reads fail closed on missing or
  # empty assets, and the pins must decode as a JSON object.
  defp build_lazy_lock_program do
    pins = Workstation.Core.Catalog.package_asset!("nvim", "files/.config/nvim/lazy-lock.json")
    template = Workstation.Core.Catalog.package_asset!("nvim", "files/modify/lazy-lock.json.sh")

    case Workstation.Core.EngineState.decode_json(pins) do
      {:ok, decoded} when is_map(decoded) -> :ok
      _ -> raise ArgumentError, "lazy-lock.json asset is not a JSON object"
    end

    String.contains?(template, @marker) ||
      raise ArgumentError, "lazy-lock merge template carries no #{@marker} marker"

    replaced = :binary.replace(template, @marker, pins)

    String.contains?(replaced, @marker) &&
      raise ArgumentError, "lazy-lock merge template substitution failed"

    replaced
  end
end
