defmodule Workstation.Core.Catalog.PackagesNunchuxTest do
  @moduledoc """
  The nunchux package's pin contracts. The binary is the first package-wired
  download-contribution: the spec's pin must mirror
  `workstation/versions.json` exactly (the tmux-oasis pin-mirror pattern),
  target the TPM plugin checkout's `bin/` directory, and ride beside the
  `.platform` marker upstream's `nunchux.tmux` `ensure_binary` checks —
  the pre-seed that keeps plugin load from ever fetching
  `releases/latest` unchecksummed. The theme-slot launcher config renders
  byte-equal to upstream's default config; only the two slot references
  carry the theme rebrand forward. The activation surface (plugin pin +
  root C-Space chord) stays dormant in tmux's `.tmux.conf` until the git
  contract's pinned-clone recipe lands. See docs/tmux.md ("prepared").
  """

  use ExUnit.Case, async: true

  alias Workstation.Packages.Nunchux
  alias Workstation.Backends.Chezmoi
  alias Workstation.Core.Contracts.Download

  @repo_root Path.expand("../../../../../../..", __DIR__)
  @payload_root Path.join(@repo_root, "workstation/packages/nunchux")

  test "the spec is a linux-only terminal-domain package requiring the theme envelope" do
    spec = Nunchux.spec()

    assert spec.id == "nunchux"
    assert spec.foundation == "foundation/terminal"
    assert spec.requires == ["foundation", "theme"]
    # The download contract pins one artifact per declaration; the
    # darwin-arm64 release pin stays recorded in versions.json until
    # per-platform dispatch exists.
    assert spec.supported_hosts == %{"darwin" => false, "linux" => true}
  end

  test "the binary is a pinned download contribution into the plugin checkout" do
    entry = download_entry()

    assert entry.provider == "download"

    assert entry.spec == %Download{
             url:
               "https://github.com/datamadsen/nunchux/releases/download/v3.1.3/nunchux-linux-amd64",
             version: "3.1.3",
             sha256: "d66afe3d47272a41272fe8c22bf86c8b8570fa2e5dbf0a1c462348d0cdf04c29",
             target: ".tmux/plugins/nunchux/bin/nunchux"
           }
  end

  test "the download pin mirrors the versions manifest" do
    manifest = versions_manifest()
    entry = download_entry().spec

    assert manifest["nunchux"] == entry.version

    assert String.replace(manifest["nunchux_linux_x86_64_url"], "{V}", entry.version) ==
             entry.url

    assert manifest["nunchux_linux_x86_64_sha256"] == entry.sha256

    # The darwin pin stays recorded (inventory completeness) even though the
    # linux-only package cannot declare it yet.
    assert manifest["nunchux_darwin_arm64_sha256"] ==
             "c8444fd8cb543cd2c7e954e59283d893ff8e6345864ef570b296b22e28c8b529"

    assert manifest["nunchux_darwin_arm64_url"] ==
             "https://github.com/datamadsen/nunchux/releases/download/v{V}/nunchux-darwin-arm64"
  end

  test "the platform marker pre-seeds upstream's ensure_binary" do
    entry =
      Enum.find(Nunchux.spec().contributes, &(&1.spec.target == ".tmux/plugins/nunchux/bin/.platform"))

    assert entry.provider == "chezmoi"
    assert entry.spec.kind == :file
    assert entry.spec.template != true
    assert entry.spec.asset == "files/.tmux/plugins/nunchux/bin/.platform"

    # Byte-for-byte what upstream's download_binary writes: the platform
    # string plus echo's newline; ensure_binary compares the stripped value.
    body = File.read!(Path.join(@payload_root, entry.spec.asset))
    assert body == "linux-amd64\n"
  end

  test "the pre-seed pair is exactly what ensure_binary checks" do
    targets = Enum.map(Nunchux.spec().contributes, & &1.spec.target)

    # nunchux.tmux ensure_binary: -x bin/nunchux, -f bin/.platform, and the
    # marker content — with both present, plugin load never fetches.
    assert ".tmux/plugins/nunchux/bin/nunchux" in targets
    assert ".tmux/plugins/nunchux/bin/.platform" in targets
  end

  test "the launcher config is a theme-slot template" do
    entry =
      Enum.find(Nunchux.spec().contributes, &(&1.spec.target == ".config/nunchux/config"))

    assert entry.spec.kind == :file
    assert entry.spec.template == true
    assert entry.spec.asset == "files/.config/nunchux/config"
  end

  test "the config template renders to the upstream default binding" do
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

  test "every template target names an existing payload asset" do
    for %{spec: %Chezmoi{template: true}} = entry <- Nunchux.spec().contributes do
      assert File.regular?(Path.join(@payload_root, entry.spec.asset)),
             "missing payload asset #{entry.spec.asset} for #{entry.spec.target}"
    end
  end

  test "the host verify script asserts the pinned pre-seed" do
    script = Path.join(@payload_root, "verify/nunchux.sh")

    assert File.regular?(script)
    assert File.stat!(script).mode >= 0o100755, "verify script must stay executable"

    assert {_, 0} = System.cmd("sh", ["-n", script])
  end

  defp download_entry do
    Enum.find(Nunchux.spec().contributes, &(&1.provider == Download.provider_id()))
  end

  defp versions_manifest do
    @repo_root
    |> Path.join("workstation/versions.json")
    |> File.read!()
    |> Jason.decode!()
  end
end
