defmodule Workstation.Core.Catalog.PackagesTmuxTest do
  @moduledoc """
  The tmux surface's pin contracts, enforced *here* because plugin checkouts
  are never managed source state. The status bar is the pinned tmux2k
  plugin at the upstream `onedark` theme with tmux2k's own separators and
  plugin icons: `.tmux.conf` must carry the active `@plugin` pin, the
  theme, the right-side plugin list (cpu/ram/time with the btop popup) and
  the clock format ahead of TPM init, `versions.json` must record the
  upstream commit + URL, and no `@oasis_*`/`@thm_*` options may be set —
  tmux2k's onedark defaults are canonical. The nunchux launcher grew into
  its own package (its payload — config target, pinned binary pre-seed,
  platform marker); this suite keeps the tmux-side contracts: the ACTIVE
  `@plugin` pin and root `C-Space` chord in `.tmux.conf` (live with the
  engine-provisioned checkout, r2.nunchux-wiring) and the tmux2k
  status-bar pins. The tmux manifest retired in the absorption chain's
  first stage — the plugin checkouts are fetchGit-pinned from the
  inventory by `modules/terminal/terminal.nix`; the engine-side pins these
  tests enforce are the payload bytes and the inventory rows. See
  docs/tmux.md.
  """

  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../../../", __DIR__)
  @payload_root Path.join(@repo_root, "workstation/packages/terminal/tmux")

  # The whole engine-provisioned set: tpm leads because it must exist
  # before the first tmux start (the run-shell at the end of .tmux.conf
  # sources it). nunchux is excluded on purpose — its checkout is owned by
  # the nunchux package, never by this one.
  @plugins [
    {"tpm", "e261deb1b47614eed3400089ce7197dc68acc4eb",
     "https://github.com/tmux-plugins/tpm"},
    {"tmux2k", "d8c5c2924c557835f984dd44eb71315b897bc4f5",
     "https://github.com/2KAbhishek/tmux2k"},
    {"tmux-yank", "acfd36e4fcba99f8310a7dfb432111c242fe7392",
     "https://github.com/tmux-plugins/tmux-yank"},
    {"tmux-resurrect", "cff343cf9e81983d3da0c8562b01616f12e8d548",
     "https://github.com/tmux-plugins/tmux-resurrect"},
    {"vim-tmux-navigator", "e41c431a0c7b7388ae7ba341f01a0d217eb3a432",
     "https://github.com/christoomey/vim-tmux-navigator"}
  ]

  test "the nunchux config target belongs to the nunchux payload" do
    # Ownership moved with the payload (the nunchux package owns the
    # theme-slot template now); tmux's payload tree must not carry it.
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

  test "the tmux2k pin, theme and right-side plugins are active ahead of TPM init" do
    lines = String.split(conf_source(), "\n")

    plugin_line = Enum.find_index(lines, &(&1 == "set -g @plugin '2KAbhishek/tmux2k'"))

    theme_line = Enum.find_index(lines, &(&1 == "set -g @tmux2k-theme 'onedark'"))

    plugins_line =
      Enum.find_index(lines, &(&1 == "set -g @tmux2k-right-plugins 'cpu ram time'"))

    popup_line = Enum.find_index(lines, &(&1 == "set -g @tmux2k-ram-popup-cmd 'btop'"))

    tpm_line =
      Enum.find_index(lines, &String.starts_with?(&1, "run-shell '~/.tmux/plugins/tpm/tpm'"))

    assert plugin_line && theme_line && plugins_line && popup_line && tpm_line
    # Every option must precede TPM init or the plugin loads without them.
    assert plugin_line < tpm_line and theme_line < tpm_line and plugins_line < tpm_line
  end

  test "the bar stays tmux2k-truthed: no theme overrides, no oasis remnants" do
    conf = conf_source()

    # tmux2k's onedark theme is canonical: no @oasis_* option may be set and
    # no starlight flavor may survive — the aurora investigation retired the
    # oasis bar entirely (its seconds clock pinned a 1Hz re-render whose
    # scroll-style repaints stacked on limited mobile clients).
    refute conf =~ "@oasis_"
    refute conf =~ "tmux-oasis"
    refute conf =~ "starlight_dark"

    # The retired slot template is gone from the payload tree; the live
    # tombstone is the terminal module's declared retire list, exercised
    # by the VM E2E's retire receipt.
    refute File.exists?(Path.join(@payload_root, "files/.config/tmux/themes/tmux2k.conf"))
  end

  test "the plugin set rides the pinned inventory" do
    manifest =
      @repo_root
      |> Path.join("workstation/versions.json")
      |> File.read!()
      |> Jason.decode!()

    for {name, commit, url} <- @plugins do
      key = String.replace(name, "-", "_")

      assert manifest["#{key}_git_commit"] == commit,
             "the #{name} pin is missing from the inventory"

      assert manifest["#{key}_git_url"] == url
      assert commit =~ ~r/\A[0-9a-f]{40}\z/
    end
  end

  defp conf_source, do: File.read!(Path.join(@payload_root, "files/.tmux.conf"))
end
