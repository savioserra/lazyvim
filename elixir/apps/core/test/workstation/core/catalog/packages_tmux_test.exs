defmodule Workstation.Core.Catalog.PackagesTmuxTest do
  @moduledoc """
  The tmux package's pin contracts, enforced *here* because plugin checkouts
  are never managed source state. The status bar is the pinned tmux-oasis
  plugin's own layout at the upstream `starlight_dark` flavor: `.tmux.conf`
  must carry the active `@plugin` pin and the flavor option ahead of TPM
  init (upstream's README install pattern), `versions.json` must record the
  upstream commit + URL, and no `@thm_*` options may be set — upstream's
  oasis_starlight_dark.conf is canonical. The nunchux launcher grew into
  its own package (Workstation.Packages.Nunchux — config target, pinned
  binary pre-seed, platform marker); this suite keeps the tmux-side
  contracts: the ACTIVE `@plugin` pin and root `C-Space` chord in
  `.tmux.conf` (live with the engine-provisioned checkout,
  r2.nunchux-wiring) and the tmux-oasis status-bar pins. See docs/tmux.md.
  """

  use ExUnit.Case, async: true

  alias Workstation.Packages.Tmux
  alias Workstation.Backends.Chezmoi

  @repo_root Path.expand("../../../../../../..", __DIR__)
  @payload_root Path.join(@repo_root, "workstation/packages/terminal/tmux")

  test "the nunchux config target moved to the nunchux package" do
    # Ownership moved with the payload (Workstation.Packages.Nunchux owns the
    # theme-slot template now); tmux must not contribute the target anymore.
    refute Enum.any?(Tmux.spec().contributes, &(&1.spec.target == ".config/nunchux/config"))
    refute File.exists?(Path.join(@payload_root, "files/.config/nunchux/config"))
  end

  test "the nunchux plugin pin is active against the engine-provisioned checkout" do
    conf = conf_source()

    # The checkout is engine-provisioned (the Workstation.Packages.Nunchux
    # pinned-clone recipe), so TPM sources the plugin; the pin must never
    # regress to a comment while the recipe — and the checkout it owns —
    # stays live.
    assert conf =~ "\nset -g @plugin 'datamadsen/nunchux'"
    refute conf =~ "#set -g @plugin 'datamadsen/nunchux'"

    assert conf =~ "pinned-clone"
    assert conf =~ "engine-provisioned"
  end

  test "the nunchux key is declared ahead of TPM init so activation needs no reorder" do
    lines = String.split(conf_source(), "\n")

    key_line = Enum.find_index(lines, &(&1 == "set -g @nunchux-key 'C-Space'"))

    tpm_line =
      Enum.find_index(lines, &String.starts_with?(&1, "run-shell '~/.tmux/plugins/tpm/tpm'"))

    assert key_line && tpm_line && key_line < tpm_line
  end

  test "the root C-Space popup binding is live beside the plugin pin" do
    lines = String.split(conf_source(), "\n")

    # Exactly the popup command nunchux.tmux builds (60%/50% are upstream's
    # menu_width/menu_height defaults; NUNCHUX_BIN resolves to the
    # engine-provisioned checkout's bin/nunchux).
    binding =
      ~S(bind -n C-Space display-popup -E -B -d '#{pane_current_path}' -w '60%' -h '50%' '~/.tmux/plugins/nunchux/bin/nunchux')

    binding_line = Enum.find_index(lines, &(&1 == binding))
    plugin_line = Enum.find_index(lines, &(&1 == "set -g @plugin 'datamadsen/nunchux'"))
    key_line = Enum.find_index(lines, &(&1 == "set -g @nunchux-key 'C-Space'"))

    assert binding_line && plugin_line && key_line
    # One activation region: pin, then key, then the chord it drives.
    assert plugin_line < binding_line and key_line < binding_line

    # No commented remnants of the dormant era may survive beside the live chord.
    refute Enum.any?(lines, &String.starts_with?(&1, "#bind -n C-Space"))
  end

  test "the tmux-oasis pin is active with the upstream starlight flavor ahead of TPM init" do
    lines = String.split(conf_source(), "\n")

    plugin_line = Enum.find_index(lines, &(&1 == "set -g @plugin 'uhs-robert/tmux-oasis'"))

    flavor_line =
      Enum.find_index(lines, &(&1 == ~s(set -g @oasis_flavor "starlight_dark")))

    tpm_line =
      Enum.find_index(lines, &String.starts_with?(&1, "run-shell '~/.tmux/plugins/tpm/tpm'"))

    assert plugin_line && flavor_line && tpm_line
    # Both options must precede TPM init or the plugin loads without them.
    assert plugin_line < tpm_line and flavor_line < tpm_line
  end

  test "the versions manifest records the tmux-oasis commit and URL" do
    manifest =
      @repo_root
      |> Path.join("workstation/versions.json")
      |> File.read!()
      |> Jason.decode!()

    assert manifest["tmux_oasis"] == "9903964ee8abdddaf08834871f12ccc093a4cbcf"
    assert manifest["tmux_oasis_url"] == "https://github.com/uhs-robert/tmux-oasis"
  end

  test "the bar stays upstream-truthed: no theme overrides, no tmux2k remnants" do
    conf = conf_source()

    # Upstream's themes/dark/oasis_starlight_dark.conf is canonical; setting
    # any @thm_* option here would fork the advertised look.
    refute conf =~ "@thm_"
    refute conf =~ "tmux2k"

    # The retired slot template is gone from the payload tree and its target
    # carries a recorded-ownership removal tombstone (already-absent no-op).
    refute File.exists?(Path.join(@payload_root, "files/.config/tmux/themes/tmux2k.conf"))

    removal =
      Enum.find(Tmux.spec().contributes, &(&1.spec.target == ".config/tmux/themes/tmux2k.conf"))

    assert removal && removal.spec.kind == :remove
    assert is_nil(removal.spec.content) and is_nil(removal.spec.asset)
  end

  test "every tmux template target names an existing payload asset" do
    for %{spec: %Chezmoi{template: true}} = entry <- Tmux.spec().contributes do
      assert File.regular?(Path.join(@payload_root, entry.spec.asset)),
             "missing payload asset #{entry.spec.asset} for #{entry.spec.target}"
    end
  end

  test "tmux contributes ride the chezmoi provider seam" do
    assert Enum.all?(Tmux.spec().contributes, &(&1.provider == "chezmoi"))
  end

  test "the tmux2k template is no longer a contributed target" do
    refute Enum.any?(Tmux.spec().contributes, fn entry ->
             entry.spec.kind == :file and entry.spec.target == ".config/tmux/themes/tmux2k.conf"
           end)
  end

  defp conf_source, do: File.read!(Path.join(@payload_root, "files/.tmux.conf"))
end
