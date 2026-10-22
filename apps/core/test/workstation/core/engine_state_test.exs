defmodule Workstation.Core.EngineStateTest do
  @moduledoc """
  Engine-state path guards are the security boundary every Elixir journal and
  provision read leans on, so they are exercised against real filesystem
  fixtures: symlinked components, foreign modes, malformed JSON and every
  fingerprint shape. All fixtures live in temporary directories; the real
  HOME is never touched.
  """

  use ExUnit.Case, async: false

  # Fixture homes are cross-VM collision-proof: `System.unique_integer/1`
  # restarts its sequence in every `mix test` VM, so a home that outlives its
  # run (a killed run's leftovers) is re-drawn verbatim by a later one. The
  # boot millisecond in base36 never repeats across VMs, any same-named
  # leftover is swept before use, and the home is removed on exit (the full
  # note lives in apps/daemon/test/workstation/daemon/generation_test.exs).
  defp unique_home(prefix) do
    token = Integer.to_string(:os.system_time(:millisecond), 36)
    home = Path.join(System.tmp_dir!(), "#{prefix}-#{token}")

    File.rm_rf!(home)
    on_exit(fn -> File.rm_rf!(home) end)
    home
  end


  alias Workstation.Core.EngineState

  setup do
    home = unique_home("workstation-b4-engine")
    File.mkdir_p!(home)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    on_exit(fn ->
      restore(previous, home)
    end)

    %{home: home}
  end

  defp restore(previous, _home) do
    if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")
  end

  defp make_state_root(home) do
    root = Path.join([home, ".local", "state", "workstation"])
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    root
  end

  test "home resolves the target home from the environment" do
    assert EngineState.home() == System.get_env("WORKSTATION_HOME")
  end

  test "state root is nested below the home, never an ambient XDG root" do
    home = EngineState.home()
    assert EngineState.state_root() == Path.join([home, ".local", "state", "workstation"])
    assert EngineState.state_components() == [".local", "state", "workstation"]
  end

  test "join_home accepts validated relative targets only" do
    home = EngineState.home()
    assert EngineState.join_home(home, "a/b") == Path.join(home, "a/b")

    assert_raise ArgumentError, ~r/invalid relative target/, fn -> EngineState.join_home(home, "/etc/passwd") end
    assert_raise ArgumentError, ~r/invalid relative target/, fn -> EngineState.join_home(home, "") end

    assert_raise ArgumentError, ~r/invalid target characters/, fn -> EngineState.join_home(home, "a\nb") end
  end

  test "verify_tree! accepts a guarded 0700 state tree" do
    make_state_root(EngineState.home())

    assert EngineState.verify_tree!(EngineState.home(), EngineState.state_components(), "engine state root") == :ok
  end

  test "verify_tree! reports absent when the walk hits a missing component" do
    assert EngineState.verify_tree!(EngineState.home(), EngineState.state_components(), "engine state root") ==
             :absent
  end

  test "verify_tree! fails closed on a wrong final mode" do
    root = make_state_root(EngineState.home())
    File.chmod!(root, 0o755)

    assert_raise ArgumentError, ~r/engine state root has mode 755, expected 700/, fn ->
      EngineState.verify_tree!(EngineState.home(), EngineState.state_components(), "engine state root")
    end
  end

  test "verify_tree! fails closed on a symlinked component" do
    home = EngineState.home()
    File.mkdir_p!(Path.join(home, "elsewhere"))
    File.ln_s!(Path.join(home, "elsewhere"), Path.join(home, ".local"))

    assert_raise ArgumentError, ~r/engine state root component is not a directory/, fn ->
      EngineState.verify_tree!(home, EngineState.state_components(), "engine state root")
    end
  end

  test "decode_json is strict: escapes, surrogate pairs and trailing garbage" do
    assert EngineState.decode_json(~s({"a": [1, 2.5, -3, true, false, null], "b": {"c": "\\u00e9"}})) ==
             {:ok, %{"a" => [1, 2.5, -3, true, false, nil], "b" => %{"c" => "é"}}}

    assert EngineState.decode_json(~s("\\ud83d\\ude00")) == {:ok, "😀"}
    assert EngineState.decode_json(~s("\\ud83d")) == {:error, :malformed}
    assert EngineState.decode_json(~s({} )) == {:ok, %{}}
    assert EngineState.decode_json(~s([])) == {:ok, []}
    assert EngineState.decode_json(~s(1 2)) == {:error, :malformed}
    assert EngineState.decode_json(~s({"a":1}x)) == {:error, :malformed}
    assert EngineState.decode_json(~s("tab\\tinside")) == {:ok, "tab\tinside"}
    assert EngineState.decode_json(~s({"a":1,})) == {:error, :malformed}
  end

  test "sha256 is the lowercase hex content digest" do
    assert EngineState.sha256("abc") ==
             "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  end
end
