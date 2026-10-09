defmodule Workstation.Core.Catalog.PackagesNvimTest do
  @moduledoc """
  The nvim package's theme surface: the editor pins the upstream oasis.nvim
  port (rebrand spec S-R4 — deliberately NOT a tokens-generated colorscheme)
  and rides starlight on all hosts (S-R2 — the Omarchy desktop-theme import
  is dropped). The `theme.lua` payload and the lazy-lock seed must stay in
  lockstep: the spec names `oasis-starlight`, the lock seeds the plugin at
  its recorded commit, and neither may resurrect tender or the Omarchy
  follow.
  """

  use ExUnit.Case, async: true

  alias Workstation.Packages.Nvim

  @repo_root Path.expand("../../../../../../..", __DIR__)
  @payload_root Path.join(@repo_root, "workstation/packages/editor/nvim")

  # Upstream `main` HEAD at pin time; the spec's recorded pin target.
  @oasis_commit "a3ef178fe47c69691e676a8da98ce5735c3013db"

  test "theme.lua pins the upstream oasis port and selects starlight" do
    body = theme_source()

    assert body =~ ~s("uhs-robert/oasis.nvim")
    assert body =~ "lazy = false"
    assert body =~ "priority = 1000"
    # `style` is the setup contract key (oasis.nvim README configuration
    # block); the colorscheme command selects the starlight port directly.
    assert body =~ "setup({ style = \"starlight\" })"
    assert body =~ "vim.cmd.colorscheme(\"oasis-starlight\")"
    assert body =~ "colorscheme = \"oasis-starlight\""
  end

  test "theme.lua no longer follows the Omarchy desktop theme or tender" do
    body = theme_source()

    # The header may note the S-R2 drop; the import machinery may not exist.
    refute body =~ "omarchy_theme_specs"
    refute body =~ "omarchy/current/theme"
    refute body =~ "loadfile"
    refute body =~ "tender"
  end

  test "the lazy-lock seed pins oasis.nvim at the recorded commit and drops tender" do
    {:ok, pins} =
      @payload_root
      |> Path.join("files/.config/nvim/lazy-lock.json")
      |> File.read!()
      |> Jason.decode()

    assert pins["oasis.nvim"] == %{"branch" => "main", "commit" => @oasis_commit}
    refute Map.has_key?(pins, "tender.vim")
  end

  test "the lockfile merge program embeds the same seed verbatim" do
    program = modify_program()

    assert program =~ @oasis_commit
    refute program =~ "tender"
  end

  defp theme_source do
    File.read!(Path.join(@payload_root, "files/.config/nvim/lua/plugins/theme.lua"))
  end

  defp modify_program do
    entry =
      Enum.find(Nvim.spec().contributes, fn entry ->
        entry.spec.target == ".config/nvim/lazy-lock.json"
      end)

    assert entry, "lazy-lock modify target missing from the nvim spec"
    entry.spec.content
  end
end
