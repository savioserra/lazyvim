defmodule Workstation.CLI.TUI.ThemeTest do
  use ExUnit.Case, async: false

  # Daemon resolution binds a real unix socket against a per-test home, so
  # this module is serial and never touches the real HOME (WORKSTATION_HOME
  # is the engine's own env contract).

  alias Workstation.CLI.TUI.Theme
  alias Workstation.Core.Theme.Tokens
  alias Workstation.Daemon.{Application, Listener}

  setup do
    home = Path.join(System.tmp_dir!(), "b7-theme-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    on_exit(fn ->
      if previous,
        do: System.put_env("WORKSTATION_HOME", previous),
        else: System.delete_env("WORKSTATION_HOME")

      File.rm_rf!(home)
    end)

    %{home: home}
  end

  test "base path mirrors the core tokens palette exactly" do
    assert Theme.base_colors(:dark) == Map.new(Tokens.palette(:dark))
    assert Theme.base_colors(:light) == Map.new(Tokens.palette(:light))

    assert Map.keys(Theme.base_colors(:dark)) |> Enum.sort() ==
             [
               :accent,
               :bg,
               :chrome,
               :err,
               :inactive,
               :muted,
               :ok,
               :ramp_end,
               :ramp_mid,
               :ramp_start,
               :selected_bg,
               :selected_fg,
               :shortcut,
               :text,
               :warn
             ]
             |> Enum.sort()
  end

  test "missing home falls back to the base palette, fail-closed" do
    resolution =
      Theme.resolve(
        home:
          Path.join(System.tmp_dir!(), "b7-no-such-home-#{System.unique_integer([:positive])}")
      )

    assert resolution.source == :base
    assert resolution.colors == Theme.base_colors(:dark)
  end

  test "resolve without a home only answers from the base palette" do
    assert Theme.resolve(appearance: :light).source == :base
    assert Theme.resolve(appearance: :light).colors == Theme.base_colors(:light)
  end

  test "daemon resolution answers with the closed role set and daemon source" do
    %{home: home} = test_ctx()

    start_supervised!(Application.supervisor_spec())
    wait_for_file(Listener.socket_path(home))

    resolution = Theme.resolve(home: home)

    assert resolution.source == :daemon
    # The daemon carries no overlays in this tree, so its resolution is the
    # same bytes the base path derives — the two paths must agree by mirror.
    assert resolution.colors == Theme.base_colors(:dark)
  end

  test "to_term_ui_color converts #rrggbb and refuses every other shape" do
    assert Theme.to_term_ui_color("#89b4fa") == {:rgb, 0x89, 0xB4, 0xFA}
    assert Theme.to_term_ui_color("#000000") == {:rgb, 0, 0, 0}
    assert Theme.to_term_ui_color("89b4fa") == nil
    assert Theme.to_term_ui_color("#89b4") == nil
    assert Theme.to_term_ui_color("#zzzzzz") == nil
    assert Theme.to_term_ui_color(:cyan) == nil
  end

  defp test_ctx, do: %{home: System.get_env("WORKSTATION_HOME")}

  defp wait_for_file(path, tries \\ 100)

  defp wait_for_file(_path, 0), do: flunk("listener socket never appeared")

  defp wait_for_file(path, tries) do
    if File.exists?(path), do: :ok, else: Process.sleep(20) && wait_for_file(path, tries - 1)
  end
end
