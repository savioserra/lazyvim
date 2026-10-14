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
  @dropped_commit "b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3"

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

    test "an activated retirement derives a retire effect before the apply effect" do
      retirement = retirement_record(".tmux/plugins/tmux-oasis")
      plan = build_plan(pins: []) |> with_retirements([retirement])

      assert [%{contract: "git", kind: :retire, phase: :target} = retire,
              %{contract: "chezmoi", kind: :apply, phase: :apply}] = Pipeline.effects(plan)

      assert retire.target == ".tmux/plugins/tmux-oasis"
      assert retire.commit == retirement.commit
      assert Map.has_key?(retire, :fingerprint) == false
    end
  end

  describe "retirement activation (the journal-driven composition boundary)" do
    test "a recorded clone whose recipe was dropped becomes a candidate; a still-pinned one does not" do
      pinned_target = ".local/share/goldens/checkouts/repo"
      dropped_target = ".tmux/plugins/tmux-oasis"

      journal = %{
        "revision" => 3,
        "generation" => "abc123",
        "targets" => %{
          pinned_target => git_record("https://goldens.invalid/git/goldens-repo.git", @commit, pinned_target),
          dropped_target => git_record("https://example.invalid/oasis.git", @dropped_commit, dropped_target),
          ".config/app/file" => %{"type" => "file", "sha256" => "x"}
        }
      }

      plan = Git.activate_retirements(build_plan(git_pins: 1), journal)

      assert [%{target: ^dropped_target, owner: "checkouts", commit: @dropped_commit}] = plan.git_retirements
    end

    test "a nil journal (fresh home, golden replay) retires nothing" do
      plan = Git.activate_retirements(build_plan(git_pins: 1), nil)
      assert plan.git_retirements == []
    end

    test "a git-typed record that lost part of its claim is corruption, not provenance" do
      dropped_target = ".tmux/plugins/tmux-oasis"

      for missing <- ["commit", "url", "owner", "source_fingerprint"] do
        record = Map.delete(git_record("https://example.invalid/oasis.git", @dropped_commit, dropped_target), missing)

        assert_raise ArgumentError, ~r/has no #{missing}/, fn ->
          Git.activate_retirements(build_plan(pins: []), %{"targets" => %{dropped_target => record}})
        end
      end
    end

    test "a record whose source fingerprint does not re-derive from the recorded pin refuses" do
      dropped_target = ".tmux/plugins/tmux-oasis"

      record =
        git_record("https://example.invalid/oasis.git", @dropped_commit, dropped_target)
        |> Map.put("source_fingerprint", String.duplicate("0", 64))

      assert_raise ArgumentError, ~r/source fingerprint does not re-derive/, fn ->
        Git.activate_retirements(build_plan(pins: []), %{"targets" => %{dropped_target => record}})
      end
    end

    test "a candidate overlapping a still-declared pin refuses in either direction" do
      pinned = %{git_pin: true, target: ".local/share/goldens/checkouts/repo"}

      record = git_record("https://example.invalid/oasis.git", @dropped_commit, ".local/share/goldens")

      assert_raise ArgumentError, ~r/never deletes through a declared checkout/, fn ->
        Git.activate_retirements(build_plan(pins: [pinned]), %{"targets" => %{".local/share/goldens" => record}})
      end

      inner_record = git_record("https://example.invalid/oasis.git", @dropped_commit, ".local/share/goldens/checkouts/repo/inner")

      assert_raise ArgumentError, ~r/never deletes through a declared checkout/, fn ->
        Git.activate_retirements(build_plan(pins: [pinned]), %{"targets" => %{".local/share/goldens/checkouts/repo/inner" => inner_record}})
      end
    end
  end

  describe "run_effect retirement against real fixture repositories" do
    test "a matching clone retires; re-running stays retired", %{home: home} do
      {url, commit} = fixture_repo(home)
      target = ".local/share/checkouts/repo"
      ctx = %{home: home}

      assert :ok = Git.Effects.run_effect(pin_effect(url, commit, target), ctx)
      directory = Path.join(home, target)
      assert File.dir?(Path.join(directory, ".git"))

      assert :ok = Git.Effects.run_effect(retire_effect(url, commit, target), ctx)
      refute File.exists?(directory), "the recorded clone is gone"

      # Idempotent arm: an absent target is already retired.
      assert :ok = Git.Effects.run_effect(retire_effect(url, commit, target), ctx)

      # The retire claim is absence, recorded as nothing.
      assert Git.Effects.fingerprint(retire_effect(url, commit, target), ctx) == %{}
    end

    test "a checkout pinned to another commit refuses with the divergence named and stays on disk", %{home: home} do
      {url, commit, other_commit} = fixture_repo(home, commits: 2)
      target = ".local/share/checkouts/repo"
      ctx = %{home: home}

      assert :ok = Git.Effects.run_effect(pin_effect(url, commit, target), ctx)

      directory = Path.join(home, target)
      git!(home, ["-C", directory, "fetch", "--quiet", "origin"])
      git!(home, ["-C", directory, "checkout", "--quiet", other_commit])

      assert_raise ArgumentError, ~r/HEAD is at #{other_commit}, but the recorded pin is #{commit}/, fn ->
        Git.Effects.run_effect(retire_effect(url, commit, target), ctx)
      end

      assert File.dir?(directory), "a refused retirement never deletes"
    end

    test "a dirty checkout refuses with the local changes named", %{home: home} do
      {url, commit} = fixture_repo(home)
      target = ".local/share/checkouts/repo"
      ctx = %{home: home}

      assert :ok = Git.Effects.run_effect(pin_effect(url, commit, target), ctx)
      File.write!(Path.join([home, target, "scratch.txt"]), "local work\n")

      assert_raise ArgumentError, ~r/local changes \(.*scratch\.txt/, fn ->
        Git.Effects.run_effect(retire_effect(url, commit, target), ctx)
      end

      assert File.dir?(Path.join(home, target))
    end

    test "a directory that is not a checkout refuses; a file at the target refuses", %{home: home} do
      {url, commit} = fixture_repo(home)
      target = ".local/share/checkouts/repo"

      File.mkdir_p!(Path.join(home, target))

      assert_raise ArgumentError, ~r/is not a git checkout/, fn ->
        Git.Effects.run_effect(retire_effect(url, commit, target), %{home: home})
      end

      File.rm_rf!(Path.join(home, target))
      File.write!(Path.join(home, target), "not a directory")

      assert_raise ArgumentError, ~r/exists as file/, fn ->
        Git.Effects.run_effect(retire_effect(url, commit, target), %{home: home})
      end
    end

    test "the retire claim raises while the checkout is still present", %{home: home} do
      {url, commit} = fixture_repo(home)
      target = ".local/share/checkouts/repo"
      ctx = %{home: home}

      assert :ok = Git.Effects.run_effect(pin_effect(url, commit, target), ctx)

      assert_raise ArgumentError, ~r/did not remove the checkout/, fn ->
        Git.Effects.fingerprint(retire_effect(url, commit, target), ctx)
      end
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

    test "a dropped recipe retires through the fold and the journal drops the record", %{home: home} do
      {url, commit} = fixture_repo(home)
      plan = build_plan(git_url: url, git_commit: commit)
      install_fake_chezmoi(home, [])

      assert Pipeline.execute(plan, %{"home" => home}) == plan.generation

      state_root = Path.join([home | EngineState.state_components()])
      target = ".local/share/goldens/checkouts/repo"
      assert File.dir?(Path.join(home, target))

      # The next composition drops the recipe: the journal still records the
      # clone, so the production boundary arms the retirement, the fold
      # removes the checkout, and the applied record drops the target.
      journal = Journal.applied(state_root)
      retired_plan = build_plan(pins: []) |> Source.with_baseline(journal) |> Git.activate_retirements(journal)

      assert [%{target: ^target, commit: ^commit}] = retired_plan.git_retirements
      assert Pipeline.execute(retired_plan, %{"home" => home}) == retired_plan.generation

      refute File.exists?(Path.join(home, target))
      refute Map.has_key?(Journal.applied(state_root)["targets"], target)
      assert Journal.applied(state_root)["revision"] == 2
      assert Journal.pending(state_root) == []

      # The retirement was a one-time convergence: re-applying the identical
      # generation derives no candidates and stays the idempotent no-op.
      reapply = build_plan(pins: []) |> Source.with_baseline(Journal.applied(state_root)) |> Git.activate_retirements(Journal.applied(state_root))
      assert reapply.git_retirements == []
      assert Pipeline.execute(reapply, %{"home" => home}) == reapply.generation
    end

    test "a drifted clone refuses the apply, anchors the failure and stays on disk", %{home: home} do
      {url, commit, other_commit} = fixture_repo(home, commits: 2)
      plan = build_plan(git_url: url, git_commit: commit)
      install_fake_chezmoi(home, [])

      assert Pipeline.execute(plan, %{"home" => home}) == plan.generation

      state_root = Path.join([home | EngineState.state_components()])
      target = ".local/share/goldens/checkouts/repo"
      directory = Path.join(home, target)

      # The operator moved HEAD behind the engine's back; the dropped recipe
      # must surface the divergence, never delete through it.
      git!(home, ["-C", directory, "fetch", "--quiet", "origin"])
      git!(home, ["-C", directory, "checkout", "--quiet", other_commit])

      journal = Journal.applied(state_root)
      retired_plan = build_plan(pins: []) |> Source.with_baseline(journal) |> Git.activate_retirements(journal)

      assert_raise ArgumentError, ~r/git retirement of #{target} refused: HEAD is at #{other_commit}/, fn ->
        Pipeline.execute(retired_plan, %{"home" => home})
      end

      assert File.dir?(directory), "a refused retirement never deletes"
      assert Journal.applied(state_root)["revision"] == 1
      assert [%{"generation" => generation}] = Journal.pending(state_root)
      assert generation == retired_plan.generation
      assert Map.has_key?(Journal.applied(state_root)["targets"], target)

      failed_dir = Path.join([state_root, "journal", "failed"])
      [name] = File.ls!(failed_dir)
      failed = Path.join(failed_dir, name) |> File.read!() |> Jason.decode!()
      assert failed["error"] =~ "retirement"
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

  # A plan carrying git pins (composed through the real provider so the
  # plan's capability profile carries the pin inventory), optional activated
  # retirements, and no entries. `pins: []` is the dropped-recipe composition
  # — the inventory the retirement activation reads.
  defp build_plan(opts) do
    url = Keyword.get(opts, :git_url, "https://goldens.invalid/git/goldens-repo.git")
    commit = Keyword.get(opts, :git_commit, @commit)
    target = ".local/share/goldens/checkouts/repo"

    pins =
      case Keyword.fetch(opts, :pins) do
        {:ok, pins} -> pins
        :error -> [pin_record(url, commit, target)]
      end

    remove_file = Policy.remove_file([])
    manifest = Manifest.build([], [{".chezmoiremove", remove_file}])

    %Source{
      entries: [],
      removals: [],
      declared_removals: [],
      unsupported_reversals: [],
      git_retirements: Keyword.get(opts, :git_retirements, []),
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

  defp pin_record(url, commit, target) do
    %{
      id: "git",
      git_pin: true,
      owner: "checkouts",
      url: url,
      commit: commit,
      target: target,
      fingerprint: Git.pin_fingerprint(url, commit, target)
    }
  end

  # The journal-shaped git claim the retirement activation reads (the exact
  # record Git.Effects.fingerprint/2 writes at claim time).
  defp git_record(url, commit, target, owner \\ "checkouts") do
    %{
      "type" => "git",
      "commit" => commit,
      "url" => url,
      "owner" => owner,
      "operation" => "clone",
      "source_fingerprint" => Git.pin_fingerprint(url, commit, target)
    }
  end

  # The plan-field retirement candidate shape (atom keys) — what
  # Git.activate_retirements/2 derives for a dropped recipe.
  defp retirement_record(target) do
    url = "https://example.invalid/oasis.git"

    %{
      target: target,
      url: url,
      commit: @dropped_commit,
      owner: "checkouts",
      source_fingerprint: Git.pin_fingerprint(url, @dropped_commit, target)
    }
  end

  defp retire_effect(url, commit, target) do
    %{
      contract: "git",
      kind: :retire,
      phase: :target,
      owner: "checkouts",
      target: target,
      url: url,
      commit: commit
    }
  end

  defp with_retirements(plan, retirements), do: %{plan | git_retirements: retirements}
end
