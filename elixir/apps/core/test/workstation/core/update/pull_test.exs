defmodule Workstation.Core.Update.PullTest do
  @moduledoc """
  The pull step against LOCAL FIXTURE repositories only: fetch and
  fast-forward, the diverged refusal (never a reset), the not-a-repo
  refusal, and owner WIP surviving a pull. No test touches a network.
  """

  use ExUnit.Case, async: false

  alias Workstation.Core.Update.Pull

  # git is the fixture transport; without it the fixtures cannot exist.
  @git_present System.find_executable("git") != nil

  setup do
    base = Path.join(System.tmp_dir!(), "c2-pull-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", base)

    on_exit(fn ->
      if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")
      File.rm_rf!(base)
    end)

    %{base: base}
  end

  @tag skip: if(@git_present, do: false, else: "git not available")
  test "fast-forwards the engine checkout to a fetched upstream commit", %{base: base} do
    origin = seed_remote!(base)
    checkout = clone!(base, origin, Path.join(base, "checkout"))
    materialize_engine_payload!(checkout)
    head = commit_to_remote!(origin, base, "second\n")

    assert {:ok, %{"step" => "pull", "status" => "ok", "head" => ^head}} = Pull.run(engine_root: checkout)
    assert git_out!(checkout, ["rev-parse", "HEAD"]) == head
  end

  @tag skip: if(@git_present, do: false, else: "git not available")
  test "a diverged upstream refuses with the checked-pull message and moves nothing", %{base: base} do
    origin = seed_remote!(base)
    checkout = clone!(base, origin, Path.join(base, "checkout"))
    materialize_engine_payload!(checkout)

    # Real divergence: the checkout carries a LOCAL commit while the remote
    # moves sideways from the same base — a checked pull must refuse, never
    # reset either side away.
    File.write!(Path.join(checkout, "local.txt"), "local work\n")
    git_out!(checkout, ["add", "."])
    git_out!(checkout, ["commit", "-q", "-m", "local"])
    before = git_out!(checkout, ["rev-parse", "HEAD"])

    sideways = clone!(base, origin, Path.join(base, "sideways"))
    File.write!(Path.join(sideways, "sideways.txt"), "sideways\n")
    git_out!(sideways, ["add", "."])
    git_out!(sideways, ["commit", "-q", "-m", "sideways"])
    git_out!(sideways, ["push", "-q", "--force", "origin", "HEAD:refs/heads/main"])
    sideways_head = git_out!(sideways, ["rev-parse", "HEAD"])
    refute sideways_head == before

    assert_raise ArgumentError, ~r/upstream is not a fast-forward.*refusing to reset/, fn ->
      Pull.run(engine_root: checkout)
    end

    assert git_out!(checkout, ["rev-parse", "HEAD"]) == before
  end

  @tag skip: if(@git_present, do: false, else: "git not available")
  test "uncommitted owner work in the checkout survives a pull", %{base: base} do
    origin = seed_remote!(base)
    checkout = clone!(base, origin, Path.join(base, "checkout"))
    materialize_engine_payload!(checkout)
    File.write!(Path.join(checkout, "wip.txt"), "owner work\n")

    commit_to_remote!(origin, base, "second\n")
    assert {:ok, %{"step" => "pull"}} = Pull.run(engine_root: checkout)

    # The dirty file is untouched: a pull is a checked fast-forward, never a
    # destructive reset of the engine source tree.
    assert File.read!(Path.join(checkout, "wip.txt")) == "owner work\n"
  end

  test "a payload-shaped checkout that is not a git repository refuses before any fetch" do
    dir = Path.join(System.tmp_dir!(), "c2-pull-nogit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    materialize_engine_payload!(dir)

    assert_raise ArgumentError, ~r/not a git repository/, fn ->
      Pull.run(engine_root: dir)
    end
  end

  # The update steps resolve the ENGINE checkout (payload markers), so a
  # fixture must be a complete one — this is also the guard that keeps a
  # fixture-less test from falling through to the real repository checkout.
  defp materialize_engine_payload!(root) do
    File.mkdir_p!(Path.join(root, "bootstrap"))
    File.mkdir_p!(Path.join(root, "bin"))
    File.write!(Path.join(root, "bootstrap/bootstrap.pins"), "fixture")
    File.write!(Path.join(root, "versions.json"), "{}")
    File.write!(Path.join(root, "bin/workstation"), "#!/bin/sh\n")
    root
  end

  ## local fixture plumbing (all git operations are filesystem-local)

  defp git_out!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], env: git_env(), stderr_to_stdout: true)
    String.trim_trailing(out)
  end

  # The fixture must be independent of the operator's git configuration,
  # exactly like the production step's pinned environment.
  defp git_env,
    do: [
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_SYSTEM", "/dev/null"},
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_AUTHOR_NAME", "fixture"},
      {"GIT_AUTHOR_EMAIL", "fixture@test"},
      {"GIT_COMMITTER_NAME", "fixture"},
      {"GIT_COMMITTER_EMAIL", "fixture@test"}
    ]

  defp seed_remote!(base) do
    origin = Path.join(base, "origin.git")
    File.mkdir_p!(origin)
    git_out!(origin, ["init", "--bare"])
    git_out!(origin, ["symbolic-ref", "HEAD", "refs/heads/main"])

    seed = Path.join(base, "seed")
    File.mkdir_p!(seed)
    git_out!(seed, ["init", "-b", "main"])
    File.write!(Path.join(seed, "first.txt"), "first\n")
    git_out!(seed, ["add", "."])
    git_out!(seed, ["commit", "-q", "-m", "first"])
    git_out!(seed, ["push", "-q", origin, "HEAD:refs/heads/main"])
    origin
  end

  defp clone!(from_dir, origin, path) do
    git_out!(from_dir, ["clone", "-q", origin, path])
    path
  end

  defp commit_to_remote!(origin, base, contents) do
    work = clone!(base, origin, Path.join(base, "push-work-#{System.unique_integer([:positive])}"))
    File.write!(Path.join(work, "second.txt"), contents)
    git_out!(work, ["add", "."])
    git_out!(work, ["commit", "-q", "-m", "second"])
    git_out!(work, ["push", "-q", "origin", "HEAD:refs/heads/main"])
    git_out!(work, ["rev-parse", "HEAD"])
  end
end
