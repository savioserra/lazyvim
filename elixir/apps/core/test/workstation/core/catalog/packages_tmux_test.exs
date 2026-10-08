defmodule Workstation.Core.Catalog.PackagesTmuxTest do
  @moduledoc """
  The tmux package's nunchux-prepared surface: the launcher config target
  rides the theme envelope like the tmux2k bar, while the plugin itself
  stays dormant in `.tmux.conf` (commented `@plugin` pin) until the engine
  grows download provisioning. Upstream's `nunchux.tmux` fetches
  `releases/latest` at load with no checksum, so the pin contract is
  enforced *here*: no active `@plugin` line, the release-asset hashes stay
  recorded in the tools manifest, and the key binding is declared ahead of
  TPM init. See docs/tmux.md ("prepared").
  """

  use ExUnit.Case, async: true

  alias Workstation.Core.Catalog.Packages.Tmux
  alias Workstation.Core.Source.Chezmoi

  @repo_root Path.expand("../../../../../../..", __DIR__)
  @payload_root Path.join(@repo_root, "workstation/packages/tmux")

  test "the spec contributes the nunchux config as a theme-slot template" do
    entry = nunchux_entry()

    assert entry.spec.kind == :file
    assert entry.spec.template == true
    assert entry.spec.asset == "files/.config/nunchux/config"
  end

  test "the config template consumes theme slots and renders to the upstream default binding" do
    body = File.read!(Path.join(@payload_root, "files/.config/nunchux/config"))

    assert body == """
           # Managed by the workstation tmux capability — theme slot template. The
           # fzf color binding is byte-equal to nunchux's upstream default config, so
           # activation introduces zero visual drift; only the two slot references
           # (text = fg+ marker, ok = marker) carry the theme rebrand forward. Slot
           # names resolve through the theme capability's .chezmoidata.toml envelope.
           [settings]
           fzf_colors = fg+:{{ .theme.slots.text }}:bold,bg+:-1,hl:cyan,hl+:cyan:bold,pointer:cyan,marker:{{ .theme.slots.ok }},header:gray,border:gray
           """

    # The slot references resolve through the theme envelope to ANSI slot
    # names; upstream's default pins fg+ to white-ish and marker to green,
    # which is exactly what the slots layer carries for text/ok.
    rendered =
      body
      |> String.replace("{{ .theme.slots.text }}", "white")
      |> String.replace("{{ .theme.slots.ok }}", "green")

    assert rendered =~
             "fzf_colors = fg+:white:bold,bg+:-1,hl:cyan,hl+:cyan:bold,pointer:cyan,marker:green,header:gray,border:gray"
  end

  test "the plugin pin stays commented out with the provisioning marker" do
    conf = conf_source()

    # Supply-chain gate: nunchux must never load, because the load path
    # fetches releases/latest unchecksummed. The pin rides as a comment
    # carrying the activation marker.
    refute conf =~ "\nset -g @plugin 'datamadsen/nunchux'"
    assert conf =~ "#set -g @plugin 'datamadsen/nunchux'"

    assert conf =~
             "# nunchux: activate when engine Source.Download provisioning lands (supply-chain S-R1; see docs/tmux.md)"
  end

  test "the nunchux key is declared ahead of TPM init so activation needs no reorder" do
    lines = String.split(conf_source(), "\n")

    key_line = Enum.find_index(lines, &(&1 == "set -g @nunchux-key 'C-Space'"))

    tpm_line =
      Enum.find_index(lines, &String.starts_with?(&1, "run-shell '~/.tmux/plugins/tpm/tpm'"))

    assert key_line && tpm_line && key_line < tpm_line
  end

  test "the root C-Space popup binding rides the activation block, commented until activation" do
    lines = String.split(conf_source(), "\n")

    # Exactly the popup command nunchux.tmux builds (60%/50% are upstream's
    # menu_width/menu_height defaults; NUNCHUX_BIN resolves to the TPM
    # checkout's bin/nunchux).
    binding =
      ~S(#bind -n C-Space display-popup -E -B -d '#{pane_current_path}' -w '60%' -h '50%' '~/.tmux/plugins/nunchux/bin/nunchux')

    binding_line = Enum.find_index(lines, &(&1 == binding))
    plugin_line = Enum.find_index(lines, &(&1 == "#set -g @plugin 'datamadsen/nunchux'"))
    key_line = Enum.find_index(lines, &(&1 == "set -g @nunchux-key 'C-Space'"))

    assert binding_line && plugin_line && key_line
    # Same commented activation region, key declared before the chord.
    assert plugin_line < binding_line and key_line < binding_line

    # A live binding today would error on the missing binary — the chord
    # must stay commented while the plugin pin is.
    refute Enum.any?(lines, &String.starts_with?(&1, "bind -n C-Space"))
  end

  test "the tools manifest pins both release assets with checksums" do
    manifest =
      @repo_root
      |> Path.join("workstation/versions.json")
      |> File.read!()
      |> Jason.decode!()

    assert manifest["nunchux"] == "3.1.3"

    assert manifest["nunchux_linux_x86_64_sha256"] ==
             "d66afe3d47272a41272fe8c22bf86c8b8570fa2e5dbf0a1c462348d0cdf04c29"

    assert manifest["nunchux_linux_x86_64_url"] ==
             "https://github.com/datamadsen/nunchux/releases/download/v{V}/nunchux-linux-amd64"

    assert manifest["nunchux_darwin_arm64_sha256"] ==
             "c8444fd8cb543cd2c7e954e59283d893ff8e6345864ef570b296b22e28c8b529"

    assert manifest["nunchux_darwin_arm64_url"] ==
             "https://github.com/datamadsen/nunchux/releases/download/v{V}/nunchux-darwin-arm64"
  end

  test "every tmux template target names an existing payload asset" do
    for %{spec: %Chezmoi{template: true}} = entry <- Tmux.spec().contributes do
      assert File.regular?(Path.join(@payload_root, entry.spec.asset)),
             "missing payload asset #{entry.spec.asset} for #{entry.spec.target}"
    end
  end

  test "tmux contributes ride the chezmoi provider seam" do
    assert Enum.all?(Tmux.spec().contributes, &(&1.provider == "chezmoi"))
    assert nunchux_entry().spec.kind == :file
  end

  defp nunchux_entry do
    Enum.find(Tmux.spec().contributes, &(&1.spec.target == ".config/nunchux/config"))
  end

  defp conf_source, do: File.read!(Path.join(@payload_root, "files/.tmux.conf"))
end
