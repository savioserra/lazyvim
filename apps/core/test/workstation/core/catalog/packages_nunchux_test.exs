defmodule Workstation.Core.Catalog.PackagesNunchuxTest do
  @moduledoc """
  The nunchux surface's pin contracts. The checkout is the first
  package-wired git contribution: the pin lives in
  `workstation/versions.json` (`nunchux_git_commit`/`nunchux_git_url`) and
  `modules/terminal/terminal.nix` fetchGit-freezes it, targeting the TPM
  plugin checkout root and owning every checkout byte — including the
  repo-tracked `bin/nunchux` the plugin runs. The `.platform` marker is
  the pre-seed upstream's `nunchux.tmux` `ensure_binary` checks: with it
  present, plugin load never fetches `releases/latest` unchecksummed. The
  release-asset pins stay recorded as distribution inventory. The
  theme-slot launcher config renders natively (slot substitution from
  `tokens.lua` through the theme extraction); the tmux-side activation
  surface (plugin pin + root C-Space chord) went live with the checkout
  (r2.nunchux-wiring). The data manifest retired in the absorption chain's
  first stage; the engine-side pins these tests enforce are the payload
  bytes and the inventory rows. See docs/tmux.md.
  """

  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../../../", __DIR__)
  @payload_root Path.join(@repo_root, "workstation/packages/terminal/nunchux")

  @nunchux_commit "1546eaa980d834c331496ea9d51942be07ea9fdd"
  @nunchux_url "https://github.com/datamadsen/nunchux"

  test "the checkout pin is a linux-only terminal-domain contribution" do
    manifest = versions_manifest()

    assert manifest["nunchux_git_commit"] == @nunchux_commit
    assert manifest["nunchux_git_url"] == @nunchux_url
  end

  test "the checkout supplies the binary; the marker is the declared pre-seed" do
    # The pinned clone owns the checkout and its tracked bin/nunchux; the
    # payload tree carries only the marker ensure_binary checks — it
    # re-downloads unchecksummed whenever bin/.platform is missing or
    # names another platform.
    assert File.regular?(Path.join(@payload_root, "files/.tmux/plugins/nunchux/bin/.platform"))
    refute File.regular?(Path.join(@payload_root, "files/.tmux/plugins/nunchux/bin/nunchux"))
  end

  test "the git pin mirrors the versions manifest" do
    manifest = versions_manifest()

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
    # Byte-for-byte what upstream's download_binary writes: the platform
    # string plus echo's newline; ensure_binary compares the stripped value.
    body = File.read!(Path.join(@payload_root, "files/.tmux/plugins/nunchux/bin/.platform"))
    assert body == "linux-amd64\n"
  end

  test "the config template renders to the upstream default binding" do
    body = File.read!(Path.join(@payload_root, "files/.config/nunchux/config"))

    assert body == """
           # Managed by the workstation tmux capability — theme slot template. The
           # fzf color binding is byte-equal to nunchux's upstream default config, so
           # activation introduces zero visual drift; only the two slot references
           # (text = fg+ marker, ok = marker) carry the theme rebrand forward. Slot
           # names resolve through the theme capability's token layer.
           [settings]
           fzf_colors = fg+:{{ .theme.slots.text }}:bold,bg+:-1,hl:cyan,hl+:cyan:bold,pointer:cyan,marker:{{ .theme.slots.ok }},header:gray,border:gray
           """

    # The slot references resolve through the theme tokens — the same
    # canonical bytes the native nix extraction reads — to ANSI slot names;
    # upstream's default pins fg+ to white-ish and marker to green, which
    # is exactly what the slots layer carries for text/ok.
    slots = Workstation.Core.Theme.Tokens.slots()

    rendered =
      body
      |> String.replace("{{ .theme.slots.text }}", Keyword.fetch!(slots, :text))
      |> String.replace("{{ .theme.slots.ok }}", Keyword.fetch!(slots, :ok))

    assert rendered =~
             "fzf_colors = fg+:white:bold,bg+:-1,hl:cyan,hl+:cyan:bold,pointer:cyan,marker:green,header:gray,border:gray"
  end

  test "the host verify script asserts the pinned checkout" do
    script = Path.join(@payload_root, "verify/nunchux.sh")

    assert File.regular?(script)
    assert File.stat!(script).mode >= 0o100755, "verify script must stay executable"

    assert {_, 0} = System.cmd("sh", ["-n", script])
  end

  defp versions_manifest do
    @repo_root
    |> Path.join("workstation/versions.json")
    |> File.read!()
    |> Jason.decode!()
  end
end
