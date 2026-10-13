defmodule Workstation.Core.Catalog.PackagesTmuxTest do
  @moduledoc """
  The tmux package's pin contracts, enforced *here* because plugin checkouts
  are never managed source state. The status bar is the pinned tmux-oasis
  plugin's own layout at the upstream `starlight_dark` flavor: `.tmux.conf`
  must carry the active `@plugin` pin and the flavor option ahead of TPM
  init (upstream's README install pattern), `versions.json` must record the
  upstream commit + URL, and no `@thm_*` options may be set — upstream's
  oasis_starlight_dark.conf is canonical. The nunchux launcher grew into
  its own package (the nunchux data manifest — config target, pinned
  binary pre-seed, platform marker); this suite keeps the tmux-side
  contracts: the ACTIVE `@plugin` pin and root `C-Space` chord in
  `.tmux.conf` (live with the engine-provisioned checkout,
  r2.nunchux-wiring) and the tmux-oasis status-bar pins. See docs/tmux.md.
  """

  use ExUnit.Case, async: true

  alias Workstation.Core.Catalog.Discover
  alias Workstation.Backends.Chezmoi

  @repo_root Path.expand("../../../../../../..", __DIR__)
  @payload_root Path.join(@repo_root, "workstation/packages/terminal/tmux")

  test "the nunchux config target moved to the nunchux package" do
    # Ownership moved with the payload (the nunchux manifest owns the
    # theme-slot template now); tmux must not contribute the target anymore.
    refute Enum.any?(tmux_spec().contributes, &(&1.spec.target == ".config/nunchux/config"))
    refute File.exists?(Path.join(@payload_root, "files/.config/nunchux/config"))
  end

  test "the nunchux plugin pin is active against the engine-provisioned checkout" do
    conf = conf_source()

    # The checkout is engine-provisioned (the nunchux manifest's
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
    # any @thm_* option here would fork the advertised look. Format *reads*
    # stay legal — the aurora clock override mirrors upstream's own module
    # pill, which reads the theme tokens (#{@thm_surface}) — so the contract
    # is write-shaped: every @thm_* mention must be a comment or a format
    # read, never an option assignment.
    assert conf
           |> String.split("\n")
           |> Enum.filter(&String.contains?(&1, "@thm_"))
           |> Enum.all?(fn line ->
             String.starts_with?(String.trim_leading(line), "#") or
               String.contains?(line, ~S(#{@thm_))
           end),
           ".tmux.conf must never set @thm_* options — comments and format reads only"

    refute conf =~ "tmux2k"

    # The retired slot template is gone from the payload tree and its target
    # carries a recorded-ownership removal tombstone (already-absent no-op).
    refute File.exists?(Path.join(@payload_root, "files/.config/tmux/themes/tmux2k.conf"))

    removal =
      Enum.find(tmux_spec().contributes, &(&1.spec.target == ".config/tmux/themes/tmux2k.conf"))

    assert removal && removal.spec.kind == :remove
    assert is_nil(removal.spec.content) and is_nil(removal.spec.asset)
  end

  test "every tmux template target names an existing payload asset" do
    for %{spec: %Chezmoi{template: true}} = entry <- tmux_spec().contributes do
      assert File.regular?(Path.join(@payload_root, entry.spec.asset)),
             "missing payload asset #{entry.spec.asset} for #{entry.spec.target}"
    end
  end

  test "tmux payloads ride the chezmoi seam; the plugin set rides pinned git recipes" do
    for entry <- tmux_spec().contributes do
      case entry.provider do
        "chezmoi" ->
          assert entry.spec.kind in [:file, :symlink, :remove]

        "git" ->
          # The engine-provisioned plugin checkouts: https pins at exact
          # commits under the managed plugin root (docs/tmux.md).
          assert String.starts_with?(entry.spec.url, "https://github.com/")
          assert entry.spec.commit =~ ~r/\A[0-9a-f]{40}\z/
          assert String.starts_with?(entry.spec.target, ".tmux/plugins/")

        other ->
          flunk("unexpected tmux provider #{inspect(other)}")
      end
    end

    # The whole engine-provisioned set, in manifest order: tpm leads because
    # it must exist before the first tmux start (the run-shell at the end of
    # .tmux.conf sources it). nunchux is excluded on purpose — its checkout
    # is owned by the nunchux package, never by this one.
    git_targets =
      tmux_spec().contributes
      |> Enum.filter(&(&1.provider == "git"))
      |> Enum.map(& &1.spec.target)

    assert git_targets == [
             ".tmux/plugins/tpm",
             ".tmux/plugins/tmux-oasis",
             ".tmux/plugins/tmux-yank",
             ".tmux/plugins/tmux-resurrect",
             ".tmux/plugins/vim-tmux-navigator"
           ]
  end

  test "the tmux2k template is no longer a contributed target" do
    refute Enum.any?(tmux_spec().contributes, fn entry ->
             entry.provider == "chezmoi" and entry.spec.kind == :file and
               entry.spec.target == ".config/tmux/themes/tmux2k.conf"
           end)
  end

  # The package's discovered spec: the data manifest read through the
  # production seam (the kernel reader's denormalized output).
  defp tmux_spec do
    Discover.specs() |> Enum.find(&(&1.id == "tmux")) ||
      raise("tmux is not discovered — the data manifest must serve the package")
  end

  defp conf_source, do: File.read!(Path.join(@payload_root, "files/.tmux.conf"))
end
