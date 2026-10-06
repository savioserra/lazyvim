defmodule Workstation.Daemon.UpdateCheckTest do
  use ExUnit.Case, async: true

  alias Workstation.Daemon.UpdateCheck

  # The fixture is a LOCAL git triangle — no network: a work repo whose
  # `origin` is a bare repository on disk (the file://-equivalent the
  # contract's test seam prescribes). `git ls-remote origin` answers from
  # the bare repo exactly as it would from a real remote.
  setup do
    tmp = Path.join([System.tmp_dir!(), "ws-update-check-#{System.unique_integer()}"])
    File.mkdir_p!(tmp)

    work = Path.join(tmp, "work")
    bare = Path.join(tmp, "origin.git")

    git = fn dir, args ->
      {out, 0} =
        System.cmd("git", ["-C", dir | args],
          stderr_to_stdout: true,
          env: [
            {"GIT_CONFIG_NOSYSTEM", "1"},
            {"GIT_CONFIG_GLOBAL", "/dev/null"},
            {"GIT_CONFIG_SYSTEM", "/dev/null"},
            {"GIT_AUTHOR_NAME", "test"},
            {"GIT_AUTHOR_EMAIL", "test@test"},
            {"GIT_COMMITTER_NAME", "test"},
            {"GIT_COMMITTER_EMAIL", "test@test"}
          ]
        )

      out
    end

    git.(tmp, ["init", "-b", "main", "work"])
    File.write!(Path.join(work, "README"), "one\n")
    git.(work, ["add", "."])
    git.(work, ["commit", "-m", "one"])
    git.(tmp, ["clone", "--bare", "work", "origin.git"])
    git.(work, ["remote", "add", "origin", bare])

    on_exit(fn -> File.rm_rf!(tmp) end)

    %{tmp: tmp, work: work, bare: bare, git: git}
  end

  describe "direct check (uncached)" do
    test "up_to_date when the local branch equals its remote counterpart", %{work: work} do
      assert %{"status" => "up_to_date"} = UpdateCheck.check(repo: work)
    end

    test "behind with short shas when the remote moved ahead", %{work: work, bare: bare, git: git} do
      # A second clone pushes past the work repo: the work repo is behind.
      twin = Path.join(Path.dirname(work), "twin")
      git.(Path.dirname(work), ["clone", "--quiet", bare, "twin"])
      File.write!(Path.join(twin, "README"), "one\ntwo\n")
      git.(twin, ["add", "."])
      git.(twin, ["commit", "-m", "two"])
      git.(twin, ["push", "--quiet", "origin", "main"])

      remote = String.trim_trailing(git.(twin, ["rev-parse", "HEAD"]))
      local = String.trim_trailing(git.(work, ["rev-parse", "HEAD"]))

      assert %{
               "status" => "behind",
               "local" => local7,
               "remote" => remote7,
               "remote_ref" => "refs/heads/main"
             } = UpdateCheck.check(repo: work)

      assert local7 == String.slice(local, 0, 7)
      assert remote7 == String.slice(remote, 0, 7)
      assert local7 != remote7
    end

    test "unknown when the repo has no origin (offline reads as no-news)", %{tmp: tmp, git: git} do
      orphan = Path.join(tmp, "orphan")
      git.(tmp, ["init", "-b", "main", "orphan"])
      File.write!(Path.join(orphan, "README"), "one\n")
      git.(orphan, ["add", "."])
      git.(orphan, ["commit", "-m", "one"])

      assert %{"status" => "unknown", "reason" => reason} = UpdateCheck.check(repo: orphan)
      assert reason =~ "cannot reach the git remote"
    end

    test "unknown for a detached HEAD", %{work: work, git: git} do
      git.(work, ["checkout", "--detach", "--quiet"])

      try do
        assert %{"status" => "unknown", "reason" => "detached or unborn HEAD"} =
                 UpdateCheck.check(repo: work)
      after
        git.(work, ["checkout", "--quiet", "main"])
      end
    end

    test "unknown when the path is not a git repository", %{tmp: tmp} do
      plain = Path.join(tmp, "plain")
      File.mkdir_p!(plain)

      assert %{"status" => "unknown", "reason" => "no git repository at " <> _} =
               UpdateCheck.check(repo: plain)
    end

    test "the fetch seam is honoured and its failures fold to unknown", %{work: work} do
      # An empty ls-remote answer: the pinned ref is missing remotely.
      assert %{"status" => "unknown", "reason" => "remote has no branch main"} =
               UpdateCheck.check(repo: work, fetch: fn _repo, _branch, _ref -> {"", 0} end)

      assert %{"status" => "unknown", "reason" => reason} =
               UpdateCheck.check(repo: work, fetch: fn _repo, _branch, _ref -> {:error, :econnrefused} end)

      assert reason =~ "git ls-remote failed"
    end  end

  describe "TTL cache (supervised op surface)" do
    test "a fresh verdict is reused until the injected clock passes the TTL", %{work: work} do
      {:ok, clock} = Agent.start_link(fn -> 1_000 end)
      name = :"#{__MODULE__}.Ttl"

      fetches = :counters.new(1, [:atomics])

      fetch = fn _repo, _branch, _ref ->
        :counters.add(fetches, 1, 1)
        {remote_head_line(work), 0}
      end

      start_supervised!(
        {UpdateCheck,
         cache: nil,
         repo: work,
         clock: fn -> Agent.get_and_update(clock, fn t -> {t, t + 1} end) end,
         fetch: fetch,
         name: name}
      )

      assert %{"status" => "up_to_date"} = UpdateCheck.check_cached(name)
      assert %{"status" => "up_to_date"} = UpdateCheck.check_cached(name)
      assert :counters.get(fetches, 1) == 1

      # Past the TTL (10 minutes of injected clock) the verdict re-checks.
      Agent.update(clock, fn t -> max(t, 1_000 + 10 * 60 * 1_000 + 1) end)
      assert %{"status" => "up_to_date"} = UpdateCheck.check_cached(name)
      assert :counters.get(fetches, 1) == 2
    end

    test "reset drops the cached verdict", %{work: work} do
      {:ok, clock} = Agent.start_link(fn -> 1_000 end)
      name = :"#{__MODULE__}.Reset"

      fetches = :counters.new(1, [:atomics])

      fetch = fn _repo, _branch, _ref ->
        :counters.add(fetches, 1, 1)
        {remote_head_line(work), 0}
      end

      start_supervised!(
        {UpdateCheck,
         cache: nil,
         repo: work,
         clock: fn -> Agent.get(clock, & &1) end,
         fetch: fetch,
         name: name}
      )

      assert %{"status" => "up_to_date"} = UpdateCheck.check_cached(name)
      assert :ok = UpdateCheck.reset(name)
      assert %{"status" => "up_to_date"} = UpdateCheck.check_cached(name)
      assert :counters.get(fetches, 1) == 2
    end

    defp remote_head_line(work) do
      {out, 0} = System.cmd("git", ["-C", work, "rev-parse", "HEAD"], stderr_to_stdout: true)
      String.trim_trailing(out) <> "\trefs/heads/main\n"
    end
  end
end
