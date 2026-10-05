defmodule Workstation.Core.UpdateTest do
  @moduledoc """
  The update lifecycle's guarded engine-checkout resolution
  (`Workstation.Core.Update.engine_root/1`: explicit option →
  `WORKSTATION_ENGINE_REPO` in either spelling → bounded dev-anchor walk,
  fail-closed) and the true-path resolver `realpath/1` (symlink splicing,
  hop-bounded against link cycles). The step suites cover the lifecycle
  verbs; this suite pins checkout ADOPTION — which directory an update is
  allowed to operate on at all.
  """

  use ExUnit.Case, async: false

  alias Workstation.Core.Update

  setup do
    previous = System.get_env("WORKSTATION_ENGINE_REPO")

    on_exit(fn ->
      if previous,
        do: System.put_env("WORKSTATION_ENGINE_REPO", previous),
        else: System.delete_env("WORKSTATION_ENGINE_REPO")
    end)

    :ok
  end

  # The payload probe is the contract: a directory is an engine checkout only
  # when bootstrap/bootstrap.pins, versions.json and bin/workstation are all
  # regular files.
  defp engine_fixture(root) do
    File.mkdir_p!(Path.join(root, "bootstrap"))
    File.mkdir_p!(Path.join(root, "bin"))
    File.write!(Path.join(root, "bootstrap/bootstrap.pins"), "pins\n")
    File.write!(Path.join(root, "versions.json"), "{}\n")
    File.write!(Path.join(root, "bin/workstation"), "#!/bin/sh\n")

    on_exit(fn -> File.rm_rf!(root) end)

    root
  end

  test "an explicit :engine_root wins over the environment" do
    payload = engine_fixture(Path.join(System.tmp_dir!(), "ws-update-root-#{System.unique_integer([:positive])}"))
    decoy = engine_fixture(Path.join(System.tmp_dir!(), "ws-update-decoy-#{System.unique_integer([:positive])}"))

    System.put_env("WORKSTATION_ENGINE_REPO", decoy)

    assert Update.engine_root(engine_root: payload) == payload
  end

  test "WORKSTATION_ENGINE_REPO resolves in both spellings" do
    # The payload lives at <tmp>/checkout/workstation so the parent spelling
    # has a real `workstation/` child to adopt.
    payload =
      engine_fixture(
        Path.join([System.tmp_dir!(), "ws-update-env-#{System.unique_integer([:positive])}", "workstation"])
      )

    # Spelling 1: the env var names the payload directory itself.
    System.put_env("WORKSTATION_ENGINE_REPO", payload)
    assert Update.engine_root([]) == payload

    # Spelling 2: the env var names the parent of a `workstation/` payload.
    parent = Path.dirname(payload)
    System.put_env("WORKSTATION_ENGINE_REPO", parent)
    assert Update.engine_root([]) == payload
  end

  test "a tree without the engine payload is never adopted (fail-closed)" do
    empty = Path.join(System.tmp_dir!(), "ws-update-empty-#{System.unique_integer([:positive])}")
    File.mkdir_p!(empty)
    System.delete_env("WORKSTATION_ENGINE_REPO")

    # Leave any dev-checkout anchor behind: from outside the repository tree
    # there is no honest checkout to guess, so resolution must raise rather
    # than update an unrelated directory.
    previous_cwd = File.cwd!()
    File.cd!(empty)

    on_exit(fn -> File.cd!(previous_cwd) end)

    assert_raise ArgumentError, ~r/no engine checkout found/, fn ->
      Update.engine_root([])
    end
  end

  test "realpath/1 splices symlink components onto the real target" do
    base = Path.join(System.tmp_dir!(), "ws-update-real-#{System.unique_integer([:positive])}")
    real = Path.join(base, "real")
    File.mkdir_p!(Path.join(real, "dir"))

    link = Path.join(base, "link")
    File.ln_s!(real, link)

    on_exit(fn -> File.rm_rf!(base) end)

    assert Update.realpath(Path.join([link, "dir", "..", "dir"])) == Path.join(real, "dir")
  end

  test "a symlink loop raises instead of looping" do
    base = Path.join(System.tmp_dir!(), "ws-update-loop-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)

    loop = Path.join(base, "loop")
    File.ln_s!(loop, loop)

    on_exit(fn -> File.rm_rf!(base) end)

    assert_raise ArgumentError, ~r/symlink loop/, fn ->
      Update.realpath(loop)
    end
  end
end
