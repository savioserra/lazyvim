defmodule Workstation.Core.EngineStateTest do
  @moduledoc """
  Engine-state path guards are the security boundary every Elixir journal and
  provision read leans on, so they are exercised against real filesystem
  fixtures: symlinked components, foreign modes, malformed JSON and every
  fingerprint shape. All fixtures live in temporary directories; the real
  HOME is never touched.
  """

  use ExUnit.Case, async: false

  alias Workstation.Core.EngineState

  setup do
    home = Path.join(System.tmp_dir!(), "workstation-b4-engine-#{:os.getpid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    on_exit(fn ->
      restore(previous, home)
    end)

    %{home: home}
  end

  defp restore(previous, home) do
    if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")
    File.rm_rf!(home)
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

  test "valid generation identifiers are exactly 64 lowercase hex characters" do
    assert EngineState.valid_generation_id(String.duplicate("a", 64))
    refute EngineState.valid_generation_id(String.upcase(String.duplicate("a", 64)))
    refute EngineState.valid_generation_id(String.duplicate("a", 63))
    refute EngineState.valid_generation_id(123)
  end

  test "generation directory is returned unverified when absent" do
    id = String.duplicate("ab", 32)
    directory = EngineState.generation_directory(EngineState.state_root(), id)
    assert directory == Path.join([EngineState.state_root(), "generations", id])
  end

  test "generation directory refuses symlinked or foreign-owned records" do
    root = make_state_root(EngineState.home())
    generations = Path.join(root, "generations")
    File.mkdir_p!(generations)
    id = String.duplicate("cd", 32)

    File.ln_s!("/nonexistent", Path.join(generations, id))

    assert_raise ArgumentError, ~r/recorded generation is not a directory/, fn ->
      EngineState.generation_directory(root, id)
    end

    File.rm!(Path.join(generations, id))
    File.mkdir!(Path.join(generations, id))
    File.chmod!(Path.join(generations, id), 0o700)
    assert EngineState.generation_directory(root, id) == Path.join(generations, id)
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

  test "read_json decodes journal payloads and resolves absent entries" do
    root = make_state_root(EngineState.home())
    journal = Path.join(root, "journal")
    File.mkdir_p!(journal)
    path = Path.join(journal, "applied.json")

    assert EngineState.read_json(path) == :absent

    File.write!(path, ~s({"generation": "abc", "revision": 2, "targets": {"a": {"mode": 420}}}))

    assert {:ok, decoded} = EngineState.read_json(path)
    assert decoded["generation"] == "abc"
    assert decoded["targets"]["a"]["mode"] == 420

    File.write!(path, "{\"generation\": ")
    assert EngineState.read_json(path) == {:error, :malformed}
  end

  test "read_json refuses journal entries that are not regular files" do
    root = make_state_root(EngineState.home())
    journal = Path.join(root, "journal")
    File.mkdir_p!(Path.join(journal, "applied.json"))

    assert_raise ArgumentError, ~r/engine journal entry is not a regular file/, fn ->
      EngineState.read_json(Path.join(journal, "applied.json"))
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

  test "target fingerprint covers file, directory, link and absent targets" do
    home = EngineState.home()
    File.write!(Path.join(home, "file.txt"), "payload")
    File.chmod!(Path.join(home, "file.txt"), 0o644)
    File.mkdir!(Path.join(home, "directory"))
    File.chmod!(Path.join(home, "directory"), 0o755)
    File.ln_s!("file.txt", Path.join(home, "link"))

    assert EngineState.target_fingerprint(home, "file.txt") == %{
             "type" => "file",
             "mode" => 0o644,
             "sha256" => EngineState.sha256("payload")
           }

    assert EngineState.target_fingerprint(home, "directory") == %{"type" => "directory", "mode" => 0o755}

    assert EngineState.target_fingerprint(home, "link") == %{
             "type" => "link",
             "mode" => 0o777,
             "link" => "file.txt"
           }

    assert EngineState.target_fingerprint(home, "absent") == nil
  end

  test "fingerprint never follows a symlinked target" do
    home = EngineState.home()
    outside = Path.join(System.tmp_dir!(), "workstation-b4-outside-#{System.unique_integer([:positive])}")
    File.write!(outside, "secret")
    File.ln_s!(outside, Path.join(home, "door"))

    on_exit(fn -> File.rm_rf!(outside) end)

    assert EngineState.target_fingerprint(home, "door")["type"] == "link"
  end
end
