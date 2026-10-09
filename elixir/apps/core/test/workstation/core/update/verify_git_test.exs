defmodule Workstation.Core.Update.VerifyGitTest do
  @moduledoc """
  The verify seam for non-file effect kinds: a git-pinned checkout's journal
  record is git-shaped (type + commit), so the file-fingerprint verification
  cannot cover it — the record routes through the owning contract's own
  verification (contract-discovered, Git.Effects re-checks HEAD against the
  pin). Verify's invariant is preserved: the journal is the ownership anchor
  and verify covers EVERY effect kind the pipeline can produce.
  """

  use ExUnit.Case, async: false

  alias Workstation.Core.Update.Verify
  alias Workstation.Core.{Digest, EngineState, Policy, Source}
  alias Workstation.Pipeline
  alias Workstation.Core.Source.Manifest
  alias Workstation.Core.Contracts.Git

  @commit "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"

  setup do
    base = Path.join(System.tmp_dir!(), "verify-git-#{System.unique_integer([:positive])}")
    home = Path.join(base, "home")
    File.mkdir_p!(home)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")
      File.rm_rf!(base)
    end)

    root = engine_payload!(Path.join(base, "engine"))
    launcher = Path.join([home, ".local", "bin", "workstation"])
    File.mkdir_p!(Path.dirname(launcher))
    File.ln_s!(Workstation.Core.Update.realpath(Path.join(root, "bin/workstation")), launcher)

    %{base: base, home: home, root: root}
  end

  test "a git-pinned checkout verifies through its contract's HEAD re-check", %{home: home, root: root} do
    {url, commit} = fixture_repo(home)
    plan = build_plan(url, commit)
    install_fake_chezmoi(home)

    assert Pipeline.execute(plan, %{"home" => home}) == plan.generation

    assert {:ok, %{"step" => "verify", "status" => "ok", "packages" => packages}} =
             Verify.run(engine_root: root, home: home)

    assert %{
             "package" => "checkouts",
             "status" => "ok",
             "drifted" => [],
             "targets" => 1
           } = Enum.find(packages, &(&1["package"] == "checkouts"))
  end

  test "a checkout whose HEAD no longer carries the pin fails verify, target named", %{home: home, root: root} do
    {url, commit, other} = fixture_repo(home, commits: 2)
    plan = build_plan(url, commit)
    install_fake_chezmoi(home)

    assert Pipeline.execute(plan, %{"home" => home}) == plan.generation

    # The pin moves behind the engine's back: verify must fail ON the
    # contract's own re-check, with the owning target named.
    directory = Path.join(home, ".local/share/goldens/checkouts/repo")
    git!(home, ["-C", directory, "fetch", "--quiet", "origin"])
    git!(home, ["-C", directory, "checkout", "--quiet", other])

    assert_raise ArgumentError, ~r/verify:.*\.local\/share\/goldens\/checkouts\/repo|git pin verify/, fn ->
      Verify.run(engine_root: root, home: home)
    end
  end

  ## fixtures (mirroring VerifyTest + GitTest: real git, fake backend)

  defp engine_payload!(root) do
    File.mkdir_p!(Path.join(root, "bootstrap"))
    File.mkdir_p!(Path.join(root, "bin"))
    File.write!(Path.join(root, "bootstrap/bootstrap.pins"), "fixture")
    File.write!(Path.join(root, "versions.json"), "{}")
    File.write!(Path.join(root, "bin/workstation"), "#!/bin/sh\n")
    root
  end

  defp fixture_repo(home, opts \\ []) do
    commits = Keyword.get(opts, :commits, 1)
    repo = Path.join(home, "fixture-origin/repo.git")
    seed = Path.join(home, "fixture-seed")
    File.mkdir_p!(seed)

    git!(home, ["init", "--quiet", "--initial-branch", "main", seed])
    git!(home, ["-C", seed, "config", "user.email", "goldens@example.invalid"])
    git!(home, ["-C", seed, "config", "user.name", "goldens"])
    File.write!(Path.join(seed, "marker.txt"), "pinned\n")
    git!(home, ["-C", seed, "add", "."])
    git!(home, ["-C", seed, "commit", "--quiet", "-m", "first"])
    first = rev_parse(seed)

    second =
      if commits >= 2 do
        File.write!(Path.join(seed, "marker.txt"), "moved\n")
        git!(home, ["-C", seed, "add", "."])
        git!(home, ["-C", seed, "commit", "--quiet", "-m", "second"])
        rev_parse(seed)
      end

    git!(home, ["clone", "--quiet", "--bare", seed, repo])
    File.rm_rf!(seed)
    if second, do: {repo, first, second}, else: {repo, first}
  end

  defp git!(home, args) do
    {_, 0} = System.cmd("git", args, env: %{"HOME" => home, "GIT_TERMINAL_PROMPT" => "0"}, stderr_to_stdout: false)
    :ok
  end

  defp rev_parse(dir) do
    {out, 0} = System.cmd("git", ["-C", dir, "rev-parse", "HEAD"], stderr_to_stdout: false)
    String.trim_trailing(out)
  end

  defp install_fake_chezmoi(home) do
    bin = Path.join([home, ".local", "opt", "chezmoi", "bin", "chezmoi"])
    File.mkdir_p!(Path.dirname(bin))
    File.write!(bin, "#!/bin/sh\nexit 0\n")
    File.chmod!(bin, 0o755)
    bin
  end

  defp build_plan(url, commit) do
    pin = %{
      id: "git",
      git_pin: true,
      owner: "checkouts",
      url: url,
      commit: commit,
      target: ".local/share/goldens/checkouts/repo",
      fingerprint: Git.pin_fingerprint(url, commit, ".local/share/goldens/checkouts/repo")
    }

    remove_file = Policy.remove_file([])
    manifest = Manifest.build([], [{".chezmoiremove", remove_file}])

    %Source{
      entries: [],
      removals: [],
      declared_removals: [],
      unsupported_reversals: [],
      profile: [pin],
      fragments_journal: %{},
      remove_file: remove_file,
      journal_revision: 0,
      baseline_generation: nil,
      data: nil,
      downloads: [],
      manifest: manifest,
      generation: Digest.sha256(Workstation.Core.CanonicalJSON.encode(manifest))
    }
  end
end
