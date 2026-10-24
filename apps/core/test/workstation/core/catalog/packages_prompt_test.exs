defmodule Workstation.Core.Catalog.PackagesPromptTest do
  @moduledoc """
  The dissolved prompt surface's payload contracts. The prompt capability
  dissolved into the foundation domain (operator ruling 2026-10-22): eza
  and starship are nixpkgs packages (no download pins — the pin rows
  retired with the manifest), the starship config deploys from the
  foundation module, and the managed rc fragments live as payload files
  beside it (`modules/foundation/fragments/`). The starship init is
  per-shell — the walker's id-keyed file map collapsed the two bodies
  (last wins); the declared lane gives each shell its own. The engine-side
  pins these tests enforce are the payload bytes and the fragment bodies.
  """

  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../../../", __DIR__)
  @payload_root Path.join(@repo_root, "workstation/packages/terminal/prompt")
  @fragments_root Path.join(@repo_root, "modules/foundation/fragments")

  @eza_body "command -v eza >/dev/null 2>&1 && alias ls='eza -lh --group-directories-first --icons=auto'"
  @starship_bash_body "command -v starship >/dev/null 2>&1 && eval \"$(starship init bash)\""
  @starship_zsh_body "command -v starship >/dev/null 2>&1 && eval \"$(starship init zsh)\""

  test "the starship config is plain lean data at .config/starship.toml" do
    body = File.read!(Path.join(@payload_root, "files/.config/starship.toml"))

    # No theme slots: the lean look is plain cyan data, not a template.
    refute body =~ "{{ .theme.slots."
    assert body =~ "success_symbol = \"[❯](bold cyan)\""
    assert body =~ "Managed by the workstation terminal/prompt capability"
  end

  test "the fragment bodies are guarded, marker-owned and interactive-only" do
    # Every body guards on resolution: a host without the tool keeps plain
    # `ls` / no prompt. The alias/init surface is the interactive shells
    # only — no .profile fragment here (the foundation PATH fragment
    # already covers it).
    assert fragment_body("managed-eza") == @eza_body

    assert fragment_body("managed-starship") == @starship_bash_body
    assert fragment_body("managed-starship-zsh") == @starship_zsh_body

    # The per-shell split is the point: bash and zsh carry DIFFERENT init
    # bodies under distinct ids (one id per fragment file — the lane's
    # uniqueness law, enforced by the aggregate's eval-time assert).
    assert @starship_bash_body != @starship_zsh_body
  end

  test "the host verify script asserts the native surface and the rc wiring" do
    script = Path.join(@payload_root, "verify/prompt.sh")

    assert File.regular?(script)
    assert File.stat!(script).mode >= 0o100755, "verify script must stay executable"
    assert {_, 0} = System.cmd("sh", ["-n", script])

    # The verify lane checks the dissolved surface: the tools speaking,
    # the payload deployed, and the fragment wiring (no pin rows — the
    # manifest they lived in retired with the absorption chain).
    script_text = File.read!(script)
    assert script_text =~ "command -v eza"
    assert script_text =~ ".config/starship.toml"
    assert script_text =~ "managed-starship-zsh.sh"
  end

  defp fragment_body(id) do
    body = File.read!(Path.join(@fragments_root, "#{id}.sh"))

    # The module deploys marker + payload; the payload file itself is the
    # body plus its documenting header line — assert the guarded body
    # survives intact on the last line.
    body
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> List.last()
  end
end
