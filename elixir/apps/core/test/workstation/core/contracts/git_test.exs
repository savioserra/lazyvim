defmodule Workstation.Core.Contracts.GitTest do
  @moduledoc """
  The pinned-clone recipe kind: recipe validation and the provider/effect
  contract split, real end-to-end clone cycles against local fixture
  repositories (real git, real shallow fetch, real detached checkout), the
  idempotent already-pinned path, every fail-closed refusal (non-checkout
  target, moved pin, tampered HEAD), and a full pipeline execute that rides
  the effects fold with zero pipeline edits — the plan carries the pins, the
  fold discovers the contract, the journal records the git-shaped claim.
  """

  use ExUnit.Case, async: false

  alias Workstation.Core.{Digest, EngineState, Journal, Policy, Source}
  alias Workstation.Pipeline
  alias Workstation.Core.Source.Manifest
  alias Workstation.Core.Contracts.Git

  @commit "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"

  setup context do
    home = Path.join(System.tmp_dir!(), "workstation-git-#{context.test}-#{:os.getpid()}")
    File.rm_rf!(home)
    File.mkdir_p!(home)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")
      File.rm_rf!(home)
    end)

    %{home: home}
  end

  describe "recipe validation" do
    test "a valid pin carries its content-addressed fingerprint" do
      pin = Git.recipe(%{url: "https://example.invalid/repo.git", commit: @commit, target: ".local/share/repo"})

      assert pin.id == "git"
      assert pin.fingerprint == Git.pin_fingerprint("https://example.invalid/repo.git", @commit, ".local/share/repo")
      assert pin.fingerprint == Digest.sha256(
               Workstation.Core.CanonicalJSON.encode(%{"commit" => @commit, "target" => ".local/share/repo", "url" => "https://example.invalid/repo.git"})
             )
    end

    test "https-only urls, 40-hex commits, safe relative literal targets" do
      assert_raise ArgumentError, ~r/must be https/, fn ->
        Git.recipe(%{url: "http://example.invalid/repo.git", commit: @commit, target: ".local/share/repo"})
      end

      assert_raise ArgumentError, ~r/40-hex lowercase sha/, fn ->
        Git.recipe(%{url: "https://example.invalid/repo.git", commit: "ABC", target: ".local/share/repo"})
      end

      assert_raise ArgumentError, ~r/must be a relative path/, fn ->
        Git.recipe(%{url: "https://example.invalid/repo.git", commit: @commit, target: "/etc/pwned"})
      end

      assert_raise ArgumentError, ~r/overlaps engine-private state/, fn ->
        Git.recipe(%{url: "https://example.invalid/repo.git", commit: @commit, target: ".local/state/workstation/x"})
      end

      assert_raise ArgumentError, ~r/unknown fields/, fn ->
        Git.validate_spec(%{url: "https://example.invalid/repo.git", commit: @commit, target: "x", branch: "main"})
      end
    end

    test "denormalize round-trips a recorded envelope through the validated recipe" do
      recorded = %{
        "url" => "https://example.invalid/repo.git",
        "commit" => @commit,
        "target" => ".local/share/repo"
      }

      assert Git.denormalize_spec(recorded) ==
               Git.recipe(%{url: recorded["url"], commit: recorded["commit"], target: recorded["target"]})
    end
  end

  describe "composition and typed effects" do
    test "compose returns the pin inventory as the provider's domain view" do
      intent = %{owner: "checkouts", spec: %{url: "https://example.invalid/repo.git", commit: @commit, target: ".local/share/repo"}}

      {record, pins} = Git.compose([intent])

      assert record.provider == "git"
      assert [%{git_pin: true, owner: "checkouts", target: ".local/share/repo", commit: @commit}] = pins
    end

    test "duplicate checkout targets conflict instead of racing" do
      intent = %{owner: "checkouts", spec: %{url: "https://example.invalid/repo.git", commit: @commit, target: ".local/share/repo"}}

      assert_raise ArgumentError, ~r/duplicate git target/, fn ->
        Git.compose([intent, %{intent | owner: "other"}])
      end
    end

    test "the fold derives clone effects before the apply effect, from the plan alone" do
      plan = build_plan(git_pins: 1)

      effects = Pipeline.effects(plan)

      assert [%{contract: "git", kind: :clone, phase: :target, target: ".local/share/goldens/checkouts/repo"} = clone,
              %{contract: "chezmoi", kind: :apply, phase: :apply}] = effects

      assert clone.commit == @commit
      assert clone.url == "https://goldens.invalid/git/goldens-repo.git"
    end
  end

  describe "run_effect against real fixture repositories" do
    test "a fresh clone lands on the pinned commit; re-running is already_pinned without fetching", %{home: home} do
      {url, commit} = fixture_repo(home)
      effect = pin_effect(url, commit, ".local/share/checkouts/repo")
      ctx = %{home: home}

      # A logging shim in front of the real git: every actual fetch appends
      # to the log, so the already-pinned assertion is evidence, not hope.
      log = fetch_log_path(home)
      shim = Path.join(home, "gitbin")
      File.mkdir_p!(shim)
      real = System.find_executable("git")

      File.write!(
        Path.join(shim, "git"),
        "#!/bin/sh\nfor arg in \"$@\"; do [ \"$arg\" = \"fetch\" ] && printf 'fetch\\n' >> \"#{log}\"; done\nexec #{real} \"$@\"\n"
      )

      File.chmod!(Path.join(shim, "git"), 0o755)
      previous = System.get_env("PATH")
      System.put_env("PATH", shim <> ":" <> (previous || ""))

      on_exit(fn ->
        if previous, do: System.put_env("PATH", previous), else: System.delete_env("PATH")
      end)

      assert :ok = Git.Effects.run_effect(effect, ctx)
      assert File.read!(Path.join([home, ".local/share/checkouts/repo", "marker.txt"])) == "pinned\n"
      assert File.read!(log) == "fetch\n", "the fresh clone fetches exactly once"

      # Idempotent pin verify: the second run reads the local HEAD and
      # neither fetches nor unshallows.
      File.rm!(log)
      assert :ok = Git.Effects.run_effect(effect, ctx)
      refute File.exists?(log), "an already-pinned re-apply must not fetch"

      # The claim verifies HEAD against the pin and records git-shaped ownership.
      assert Git.Effects.fingerprint(effect, ctx) ==
               %{".local/share/checkouts/repo" =>
                   %{
                     "type" => "git",
                     "commit" => commit,
                     "url" => url,
                     "owner" => "checkouts",
                     "operation" => "clone",
                     "source_fingerprint" => effect.fingerprint
                   }}
    end

    test "a checkout pinned to a different commit is never moved", %{home: home} do
      {url, commit, other_commit} = fixture_repo(home, commits: 2)
      effect = pin_effect(url, commit, ".local/share/checkouts/repo")
      moved = %{effect | commit: other_commit}

      assert :ok = Git.Effects.run_effect(effect, %{home: home})

      assert_raise ArgumentError, ~r/refusing to move it/, fn ->
        Git.Effects.run_effect(moved, %{home: home})
      end
    end

    test "a directory that is not a checkout refuses pin verify", %{home: home} do
      {url, commit} = fixture_repo(home)
      File.mkdir_p!(Path.join(home, ".local/share/checkouts/repo"))

      assert_raise ArgumentError, ~r/is not a git checkout/, fn ->
        Git.Effects.run_effect(pin_effect(url, commit, ".local/share/checkouts/repo"), %{home: home})
      end
    end

    test "a tampered HEAD fails the claim instead of recording ownership", %{home: home} do
      {url, commit, other_commit} = fixture_repo(home, commits: 2)
      effect = pin_effect(url, commit, ".local/share/checkouts/repo")
      ctx = %{home: home}

      assert :ok = Git.Effects.run_effect(effect, ctx)

      # Move HEAD behind the pipeline's back (the shallow clone only has the
      # pinned commit, so fetch the fixture history first): the claim must
      # fail closed.
      directory = Path.join(home, ".local/share/checkouts/repo")
      git!(home, ["-C", directory, "fetch", "--quiet", "origin"])
      git!(home, ["-C", directory, "checkout", "--quiet", other_commit])

      assert_raise ArgumentError, ~r/git pin verify failed/, fn ->
        Git.Effects.fingerprint(effect, ctx)
      end
    end
  end

  describe "pipeline integration (zero pipeline edits)" do
    test "a git-only plan rides the fold: clone, claim, journal, idempotent re-apply", %{home: home} do
      {url, commit} = fixture_repo(home)
      plan = build_plan(git_url: url, git_commit: commit)
      install_fake_chezmoi(home, [])

      assert Pipeline.execute(plan, %{"home" => home}) == plan.generation

      state_root = Path.join([home | EngineState.state_components()])
      record = Journal.applied(state_root)

      assert %{
               ".local/share/goldens/checkouts/repo" => %{
                 "type" => "git",
                 "commit" => ^commit,
                 "operation" => "clone"
               }
             } = record["targets"]

      assert File.dir?(Path.join([home, ".local/share/goldens/checkouts/repo", ".git"]))
      assert Journal.pending(state_root) == []

      # Re-applying the identical desired generation is the idempotent no-op.
      assert Pipeline.execute(plan, %{"home" => home}) == plan.generation
      assert Journal.applied(state_root)["revision"] == 2
    end

    test "a failing clone records journal/failed and keeps the pending anchor", %{home: home} do
      # A remote that does not exist: the fetch fails, the fold fails.
      plan = build_plan(git_url: "https://goldens.invalid/nowhere.git")
      install_fake_chezmoi(home, [])

      assert_raise ArgumentError, ~r/git failed/, fn ->
        Pipeline.execute(plan, %{"home" => home})
      end

      state_root = Path.join([home | EngineState.state_components()])
      assert Journal.applied(state_root) == nil
      assert [%{"generation" => generation}] = Journal.pending(state_root)
      assert generation == plan.generation

      failed_dir = Path.join([state_root, "journal", "failed"])
      [name] = File.ls!(failed_dir)
      failed = Path.join(failed_dir, name) |> File.read!() |> Jason.decode!()
      assert failed["error"] =~ "git"
    end
  end

  ## fixtures

  # A real local git repository: one or two commits on main, a marker file
  # for content assertions. Returns {url, first_commit} or {url, first,
  # second}. The url is a plain local path — run_effect does not re-validate
  # urls (declared pins are https; the fixture exercises the clone
  # mechanics, not the supply-chain posture, which the recipe tests pin).
  defp fixture_repo(home, opts \\ []) do
    commits = Keyword.get(opts, :commits, 1)
    repo = Path.join(home, "fixture-origin/repo.git")
    seed = Path.join(home, "fixture-seed")
    File.rm_rf!(seed)
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

  defp git!(home, args), do: git!(System.find_executable("git"), home, args)

  defp git!(git, home, args) do
    {_, 0} = System.cmd(git, args, env: %{"HOME" => home, "GIT_TERMINAL_PROMPT" => "0"}, stderr_to_stdout: false)
    :ok
  end

  defp rev_parse(dir) do
    {out, 0} = System.cmd("git", ["-C", dir, "rev-parse", "HEAD"], stderr_to_stdout: false)
    String.trim_trailing(out)
  end

  # Local fixture remotes are plain paths — the effect/pin maps are built
  # literally (the https supply-chain posture is pinned by the recipe tests
  # against .invalid urls; the mechanics tests exercise clone/verify).
  defp pin_effect(url, commit, target) do
    %{
      contract: "git",
      kind: :clone,
      phase: :target,
      owner: "checkouts",
      target: target,
      url: url,
      commit: commit,
      fingerprint: Git.pin_fingerprint(url, commit, target)
    }
  end

  # The fetch log the git shim appends to on every actual fetch — the
  # already-pinned assertion reads its absence.
  defp fetch_log_path(home), do: Path.join(home, "fetches.log")

  defp install_fake_chezmoi(home, instructions) do
    bin = Path.join([home, ".local", "opt", "chezmoi", "bin", "chezmoi"])
    File.mkdir_p!(Path.dirname(bin))
    File.write!(bin <> ".instructions", instructions)

    File.write!(
      bin,
      "#!/bin/sh\nfor arg in \"$@\"; do printf '%s\\n' \"$arg\" >> \"#{bin}.argv\"; done\nsh \"#{bin}.instructions\"\n"
    )

    File.chmod!(bin, 0o755)
    bin
  end

  # A plan carrying one git pin (composed through the real provider so the
  # plan's capability profile carries the pin inventory) and no entries.
  defp build_plan(opts) do
    url = Keyword.get(opts, :git_url, "https://goldens.invalid/git/goldens-repo.git")
    commit = Keyword.get(opts, :git_commit, @commit)

    pins = [
      %{
        id: "git",
        git_pin: true,
        owner: "checkouts",
        url: url,
        commit: commit,
        target: ".local/share/goldens/checkouts/repo",
        fingerprint: Git.pin_fingerprint(url, commit, ".local/share/goldens/checkouts/repo")
      }
    ]

    remove_file = Policy.remove_file([])
    manifest = Manifest.build([], [{".chezmoiremove", remove_file}])

    %Source{
      entries: [],
      removals: [],
      declared_removals: [],
      unsupported_reversals: [],
      profile: pins,
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
