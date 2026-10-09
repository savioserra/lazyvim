defmodule Workstation.Core.Catalog.PackagesNunchuxTest do
  @moduledoc """
  The nunchux package's pin contracts. The checkout is the first
  package-wired git contribution: the spec's pin must mirror
  `workstation/versions.json` exactly (the tmux-oasis pin-mirror pattern),
  target the TPM plugin checkout root, and own every checkout byte —
  including the repo-tracked `bin/nunchux` the plugin runs. The `.platform`
  marker is the pre-seed upstream's `nunchux.tmux` `ensure_binary` checks:
  with it present, plugin load never fetches `releases/latest`
  unchecksummed. The release-asset pins stay recorded as distribution
  inventory. The theme-slot launcher config renders byte-equal to
  upstream's default config; the tmux-side activation surface (plugin pin
  + root C-Space chord) went live with the checkout (r2.nunchux-wiring).
  See docs/tmux.md.
  """

  use ExUnit.Case, async: true

  alias Workstation.Packages.Nunchux
  alias Workstation.Core.Contracts.Git
  alias Workstation.Backends.Chezmoi

  @repo_root Path.expand("../../../../../../..", __DIR__)
  @payload_root Path.join(@repo_root, "workstation/packages/terminal/nunchux")

  test "the spec is a linux-only terminal-domain package requiring the theme envelope" do
    spec = Nunchux.spec()

    assert spec.id == "nunchux"
    assert spec.foundation == "foundation/terminal"
    assert spec.requires == ["foundation", "theme"]
    # The checkout carries the linux-amd64 repo build; the darwin-arm64
    # release pin stays recorded in versions.json until per-platform
    # dispatch exists.
    assert spec.supported_hosts == %{"darwin" => false, "linux" => true}
  end

  test "the checkout is a pinned-clone contribution into the plugin root" do
    entry = git_entry()

    assert entry.provider == "git"
    assert entry.spec.id == "git"
    assert entry.spec.url == "https://github.com/datamadsen/nunchux"
    assert entry.spec.commit == "1546eaa980d834c331496ea9d51942be07ea9fdd"
    assert entry.spec.target == ".tmux/plugins/nunchux"

    assert entry.spec.fingerprint ==
             Git.pin_fingerprint(entry.spec.url, entry.spec.commit, entry.spec.target)

    # Exactly one owner of the checkout root; the sibling targets live
    # inside the cloned tree.
    assert Nunchux.spec().contributes |> Enum.count(&(&1.provider == "git")) == 1
  end

  test "the git pin mirrors the versions manifest" do
    manifest = versions_manifest()
    pin = git_entry().spec

    assert manifest["nunchux_git_commit"] == pin.commit
    assert manifest["nunchux_git_url"] == pin.url

    # The checkout carries the upstream repo build of the same release; its
    # content pin rides versions.json and is asserted by the verify lane
    # (never executed there).
    assert manifest["nunchux_repo_linux_amd64_sha256"] ==
             "8a6e46d937ee76ac6a483865c800de9208aabbe1dbc620473eb5e6b7d86b7b14"

    # The release-asset pins stay recorded as distribution inventory, even
    # though the checkout (not the artifact) supplies the binary now.
    assert manifest["nunchux"] == "3.1.3"

    assert String.replace(manifest["nunchux_linux_x86_64_url"], "{V}", "3.1.3") ==
             "https://github.com/datamadsen/nunchux/releases/download/v3.1.3/nunchux-linux-amd64"

    assert manifest["nunchux_linux_x86_64_sha256"] ==
             "d66afe3d47272a41272fe8c22bf86c8b8570fa2e5dbf0a1c462348d0cdf04c29"

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

  test "the checkout supplies the binary; the marker is the declared pre-seed" do
    targets = Enum.map(Nunchux.spec().contributes, &(&1.spec.target))

    # The pinned clone owns the checkout and its tracked bin/nunchux;
    # the marker is what ensure_binary checks — it re-downloads
    # unchecksummed whenever bin/.platform is missing or names another
    # platform.
    assert ".tmux/plugins/nunchux" in targets
    assert ".tmux/plugins/nunchux/bin/.platform" in targets
    refute ".tmux/plugins/nunchux/bin/nunchux" in targets
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

  test "the host verify script asserts the pinned checkout" do
    script = Path.join(@payload_root, "verify/nunchux.sh")

    assert File.regular?(script)
    assert File.stat!(script).mode >= 0o100755, "verify script must stay executable"

    assert {_, 0} = System.cmd("sh", ["-n", script])
  end

  defp git_entry do
    Enum.find(Nunchux.spec().contributes, &(&1.provider == "git"))
  end

  defp versions_manifest do
    @repo_root
    |> Path.join("workstation/versions.json")
    |> File.read!()
    |> Jason.decode!()
  end
end
